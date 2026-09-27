import Foundation
import Observation
import OSLog
import WebKit

private let log = Logger(subsystem: "com.browser.Freedom", category: "Downloads")

/// One tracked download (desktop "Download Manager" parity). Persisted
/// in the index next to the files; the file itself lives in
/// `DownloadManager.directory`.
struct DownloadItem: Identifiable, Codable, Equatable, Sendable {
    enum State: Codable, Equatable, Sendable {
        case inProgress
        /// Cancelled with resume data (user pause or a transport failure
        /// WebKit can continue from).
        case paused
        case completed
        case failed(String)
        case cancelled
    }
    let id: UUID
    let sourceURL: String
    var filename: String
    var mimeType: String?
    var bytesReceived: Int64
    var totalBytes: Int64?
    var state: State
    let startedAt: Date
    var finishedAt: Date?

    var canResume: Bool { state == .paused }
    var isActive: Bool { state == .inProgress }
    var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(bytesReceived) / Double(totalBytes))
    }
}

/// Every download — http(s), `bzz://`, `ipfs://`/`ipns://`, data URIs —
/// tracked with progress, pause/resume and cancel; files land in the
/// app's Documents/Downloads and open through Quick Look or the share
/// sheet (which offers Save to Files). Files are never opened
/// automatically. The manager is the `WKDownloadDelegate` for every
/// download a tab hands it.
@MainActor
@Observable
final class DownloadManager: NSObject {
    static let shared = DownloadManager()

    /// Newest first.
    private(set) var items: [DownloadItem] = []
    /// Set for a few seconds after a download completes: drives the shelf.
    private(set) var recentlyCompleted: UUID?

    let directory: URL
    private let indexURL: URL
    @ObservationIgnored private var active: [UUID: WKDownload] = [:]
    @ObservationIgnored private var resumeData: [UUID: Data] = [:]
    @ObservationIgnored private var progressObservations: [UUID: NSKeyValueObservation] = [:]
    @ObservationIgnored private var originWebViews: [UUID: WeakWebView] = [:]
    @ObservationIgnored private var completionDismissTask: Task<Void, Never>?

    private struct WeakWebView { weak var webView: WKWebView? }

    var hasActive: Bool { items.contains { $0.isActive } }

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        self.directory = base
        self.indexURL = base.appendingPathComponent(".index.json")
        super.init()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let stored = try? JSONDecoder().decode([DownloadItem].self, from: data)
        {
            // A download that was in flight when the app died cannot be
            // continued (no resume data survives) — it is a failure now.
            items = stored.map { item in
                var item = item
                if item.isActive { item.state = .failed("Interrupted") }
                return item
            }
        }
    }

    func fileURL(for item: DownloadItem) -> URL { directory.appendingPathComponent(item.filename) }

    func item(id: UUID) -> DownloadItem? { items.first { $0.id == id } }

    // MARK: - Adoption (from the tab's navigation delegate)

    /// Take ownership of a download WebKit created for a navigation
    /// action or response; the originating web view is remembered so a
    /// paused download can be resumed through it.
    func adopt(_ download: WKDownload, sourceURL: URL?, mimeType: String?, from webView: WKWebView?) {
        let id = UUID()
        let item = DownloadItem(
            id: id, sourceURL: sourceURL?.absoluteString ?? "", filename: "", mimeType: mimeType,
            bytesReceived: 0, totalBytes: nil, state: .inProgress, startedAt: Date(), finishedAt: nil
        )
        items.insert(item, at: 0)
        attach(download, to: id, webView: webView)
        log.notice("[downloads] started \(sourceURL?.absoluteString ?? "?", privacy: .public)")
    }

    private func attach(_ download: WKDownload, to id: UUID, webView: WKWebView?) {
        download.delegate = self
        active[id] = download
        if let webView { originWebViews[id] = WeakWebView(webView: webView) }
        progressObservations[id] = download.progress.observe(\.completedUnitCount, options: [.new]) { [weak self] progress, _ in
            let received = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { @MainActor [weak self] in
                self?.applyProgress(id: id, received: received, total: total > 0 ? total : nil)
            }
        }
    }

    private func idFor(_ download: WKDownload) -> UUID? {
        active.first { $0.value === download }?.key
    }

    // MARK: - Mutations (pure over items; unit-tested)

    func applyProgress(id: UUID, received: Int64, total: Int64?) {
        update(id) { item in
            item.bytesReceived = received
            if let total { item.totalBytes = total }
        }
    }

    func markCompleted(id: UUID) {
        update(id) { item in
            item.state = .completed
            item.finishedAt = Date()
            if let total = item.totalBytes { item.bytesReceived = total }
        }
        finishActive(id)
        recentlyCompleted = id
        completionDismissTask?.cancel()
        completionDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            if self?.recentlyCompleted == id { self?.recentlyCompleted = nil }
        }
    }

    func markFailed(id: UUID, message: String, resumeData data: Data?) {
        update(id) { item in
            item.state = data == nil ? .failed(message) : .paused
            item.finishedAt = Date()
        }
        if let data { resumeData[id] = data }
        finishActive(id)
    }

    private func finishActive(_ id: UUID) {
        active[id] = nil
        progressObservations[id]?.invalidate()
        progressObservations[id] = nil
    }

    private func update(_ id: UUID, _ body: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[index])
        persist()
    }

    /// A filename in `directory` that does not collide: `name.ext`,
    /// `name (2).ext`, … Sanitized against path separators.
    static func uniqueFilename(_ suggested: String, existing: (String) -> Bool) -> String {
        var base = suggested.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base == "." || base == ".." { base = "download" }
        if base.hasPrefix(".") { base = "_" + base }
        guard existing(base) else { return base }
        let ext = (base as NSString).pathExtension
        let stem = ext.isEmpty ? base : String(base.dropLast(ext.count + 1))
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            if !existing(candidate) { return candidate }
            n += 1
        }
    }

    // MARK: - User actions

    func cancel(id: UUID) {
        guard let download = active[id] else { return }
        download.cancel { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.update(id) { $0.state = .cancelled; $0.finishedAt = Date() }
                self?.finishActive(id)
            }
        }
    }

    /// Pause = cancel keeping WebKit's resume data.
    func pause(id: UUID) {
        guard let download = active[id] else { return }
        download.cancel { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data {
                    resumeData[id] = data
                    update(id) { $0.state = .paused }
                } else {
                    update(id) { $0.state = .cancelled; $0.finishedAt = Date() }
                }
                finishActive(id)
            }
        }
    }

    /// Continue a paused download through its originating web view, or
    /// `fallback` (any live tab) when that view is gone.
    func resume(id: UUID, fallback: WKWebView?) {
        guard let data = resumeData[id], let webView = originWebViews[id]?.webView ?? fallback else { return }
        resumeData[id] = nil
        update(id) { $0.state = .inProgress; $0.finishedAt = nil }
        webView.resumeDownload(fromResumeData: data) { [weak self] download in
            Task { @MainActor [weak self] in
                self?.attach(download, to: id, webView: webView)
            }
        }
    }

    /// Remove the entry and its file.
    func remove(id: UUID) {
        if active[id] != nil { cancel(id: id) }
        if let item = item(id: id), !item.filename.isEmpty {
            try? FileManager.default.removeItem(at: fileURL(for: item))
        }
        items.removeAll { $0.id == id }
        resumeData[id] = nil
        originWebViews[id] = nil
        if recentlyCompleted == id { recentlyCompleted = nil }
        persist()
    }

    func clearAll() {
        for item in items { remove(id: item.id) }
    }

    func dismissShelf() { recentlyCompleted = nil }

    /// Insert an item without a WebKit download (tests).
    func seedForTesting(_ item: DownloadItem) {
        items.insert(item, at: 0)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: indexURL, options: .atomic) }
    }
}

extension DownloadManager: WKDownloadDelegate {
    nonisolated func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        Task { @MainActor in
            guard let id = idFor(download) else { completionHandler(nil); return }
            let name = Self.uniqueFilename(suggestedFilename) { candidate in
                FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path)
                    || items.contains { $0.id != id && $0.filename == candidate }
            }
            update(id) { item in
                item.filename = name
                if item.mimeType == nil { item.mimeType = response.mimeType }
                if response.expectedContentLength > 0 { item.totalBytes = response.expectedContentLength }
            }
            completionHandler(directory.appendingPathComponent(name))
        }
    }

    nonisolated func downloadDidFinish(_ download: WKDownload) {
        Task { @MainActor in
            guard let id = idFor(download) else { return }
            markCompleted(id: id)
            log.notice("[downloads] finished \(self.item(id: id)?.filename ?? "?", privacy: .public)")
        }
    }

    nonisolated func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        Task { @MainActor in
            guard let id = idFor(download) else { return }
            markFailed(id: id, message: error.localizedDescription, resumeData: resumeData)
            log.notice("[downloads] failed \(error.localizedDescription, privacy: .public) resumable=\(resumeData != nil)")
        }
    }
}
