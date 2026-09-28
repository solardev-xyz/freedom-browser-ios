import Foundation
import Observation
import OSLog
import UniformTypeIdentifiers

private let log = Logger(subsystem: "com.browser.Freedom", category: "SwarmUserPublisher")

/// User-initiated publishing — desktop's `freedom://publish` page and
/// `publish-service.js`. Publishes a file, a folder (as a collection
/// with `index.html` auto-detected as the index document) or typed
/// text through the node, records the result in the publish history
/// under the `freedom://publish` origin, and tracks upload progress
/// through bee's tag until every chunk is dispatched.
@MainActor
@Observable
final class SwarmUserPublisher {
    /// Origin recorded for user-initiated publishes (desktop `USER_ORIGIN`).
    static let userOrigin = "freedom://publish"
    /// Whole payloads are held in memory for the upload, so cap what a
    /// phone will take on in one go.
    static let maxBytes = 100 * 1024 * 1024
    static let progressPoll: Duration = .seconds(2)
    static let progressTimeout: TimeInterval = 600

    enum Source: Equatable {
        case text(String)
        case file(URL)
        case folder(URL)
    }

    struct Result: Equatable {
        let reference: String
        let name: String?
        var bzzURL: URL { URL(string: "bzz://\(reference)/")! }
    }

    enum State: Equatable {
        case idle
        case uploading(label: String, progress: Int?)
        case done(Result)
        case failed(String)
    }

    enum Error: Swift.Error, Equatable, LocalizedError {
        case noUsableStamps
        case tooLarge(bytes: Int)
        case emptyFolder
        case unreadable(String)
        case pathTooLong(String)

        var errorDescription: String? {
            switch self {
            case .noUsableStamps: "No usable postage stamps. Buy a stamp before publishing."
            case .tooLarge(let bytes): "Too large to publish from this device (\(bytes.formatted(.byteCount(style: .file)))); the limit is \(SwarmUserPublisher.maxBytes.formatted(.byteCount(style: .file)))."
            case .emptyFolder: "The folder contains no files."
            case .unreadable(let name): "Couldn't read \(name)."
            case .pathTooLong(let path): "A path in the folder is longer than 100 bytes: \(path)"
            }
        }
    }

    /// One prepared upload — what the picker yielded, before bee sees it.
    struct Payload: Equatable {
        enum Body: Equatable {
            case single(data: Data, contentType: String, name: String)
            case collection(tar: Data, indexDocument: String?, name: String)
        }
        let body: Body
        let bytes: Int
        var kind: SwarmPublishKind {
            if case .single = body { return .data }
            return .files
        }
        var name: String {
            switch body {
            case .single(_, _, let name), .collection(_, _, let name): name
            }
        }
    }

    private(set) var state: State = .idle

    @ObservationIgnored private let publishService: SwarmPublishService
    @ObservationIgnored private let history: SwarmPublishHistoryStore
    @ObservationIgnored private let currentStamps: @MainActor () -> [PostageBatch]
    @ObservationIgnored private let getTag: @MainActor (Int) async throws -> BeeAPIClient.TagResponse
    /// The in-flight publish, so "Publish another" / leaving the page
    /// can cancel the progress follow-up.
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        publishService: SwarmPublishService,
        history: SwarmPublishHistoryStore,
        currentStamps: @escaping @MainActor () -> [PostageBatch],
        getTag: @escaping @MainActor (Int) async throws -> BeeAPIClient.TagResponse
    ) {
        self.publishService = publishService
        self.history = history
        self.currentStamps = currentStamps
        self.getTag = getTag
    }

    func reset() {
        task?.cancel()
        task = nil
        state = .idle
    }

    /// Fire-and-observe entry point for the page.
    func start(_ source: Source) {
        task?.cancel()
        task = Task { await publish(source) }
    }

    /// Prepare, upload, record, then follow the tag. Errors land in
    /// `.failed` with a sentence the page shows verbatim.
    func publish(_ source: Source) async {
        let label: String
        switch source {
        case .text: label = "Publishing text…"
        case .file: label = "Uploading file…"
        case .folder: label = "Uploading folder…"
        }
        state = .uploading(label: label, progress: nil)

        let payload: Payload
        do {
            payload = try Self.prepare(source)
        } catch {
            state = .failed(Self.describe(error))
            return
        }
        guard let batch = StampService.selectBestBatch(forBytes: payload.bytes, in: currentStamps()) else {
            state = .failed(Self.describe(Error.noUsableStamps))
            return
        }

        let row = history.record(
            kind: payload.kind, name: payload.name, origin: Self.userOrigin, bytesSize: payload.bytes
        )
        let upload: SwarmPublishService.UploadResult
        do {
            switch payload.body {
            case .single(let data, let contentType, let name):
                upload = try await publishService.publishData(
                    data, contentType: contentType, name: name, batchID: batch.batchID
                )
            case .collection(let tar, let indexDocument, _):
                upload = try await publishService.publishFiles(
                    tar, indexDocument: indexDocument, batchID: batch.batchID
                )
            }
        } catch {
            let message = Self.describe(error)
            history.fail(row, errorMessage: message)
            state = .failed(message)
            return
        }
        history.complete(row, reference: upload.reference, tagUid: upload.tagUid, batchId: batch.batchID)
        log.info("published \(payload.name, privacy: .public) → \(upload.reference, privacy: .public)")
        guard !Task.isCancelled else { return }

        let result = Result(reference: upload.reference, name: payload.name)
        if let tagUid = upload.tagUid {
            let sending = label.replacingOccurrences(of: "Uploading", with: "Sending")
            state = .uploading(label: sending, progress: 0)
            await followTag(tagUid, label: sending)
        }
        if !Task.isCancelled, case .uploading = state { state = .done(result) }
    }

    /// Desktop's `pollProgress`: `sent / split` every 2 s until every
    /// chunk is dispatched or 10 minutes pass. The reference is already
    /// final, so a timeout or a tag bee forgot still ends in `.done`.
    private func followTag(_ tagUid: Int, label: String) async {
        let deadline = Date().addingTimeInterval(Self.progressTimeout)
        while Date() < deadline, !Task.isCancelled {
            if let tag = try? await getTag(tagUid) {
                guard !Task.isCancelled else { return }
                state = .uploading(label: label, progress: tag.progressPercent)
                if tag.isDone { return }
            } else {
                return
            }
            try? await Task.sleep(for: Self.progressPoll)
        }
    }

    // MARK: - Preparation (pure, testable)

    static func prepare(_ source: Source) throws -> Payload {
        switch source {
        case .text(let text):
            let data = Data(text.utf8)
            try checkSize(data.count)
            return Payload(body: .single(data: data, contentType: "text/plain; charset=utf-8", name: "text.txt"), bytes: data.count)
        case .file(let url):
            let data = try withScopedAccess(url) { try Data(contentsOf: url) }
            try checkSize(data.count)
            return Payload(
                body: .single(data: data, contentType: mimeType(for: url), name: url.lastPathComponent),
                bytes: data.count
            )
        case .folder(let url):
            let (entries, bytes) = try withScopedAccess(url) { try collect(folder: url) }
            let tar: Data
            do {
                tar = try TarBuilder.build(entries: entries)
            } catch TarBuilder.Error.pathTooLong(let path) {
                throw Error.pathTooLong(path)
            }
            let index = entries.contains { $0.path == "index.html" } ? "index.html" : nil
            return Payload(
                body: .collection(tar: tar, indexDocument: index, name: url.lastPathComponent),
                bytes: bytes
            )
        }
    }

    /// Every regular file under `folder`, paths relative to it with `/`
    /// separators, sorted for a deterministic archive. Finder's
    /// `.DS_Store` is the one thing skipped — nobody means to publish it.
    static func collect(folder: URL) throws -> (entries: [TarBuilder.Entry], bytes: Int) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.producesRelativePathURLs]
        ) else { throw Error.unreadable(folder.lastPathComponent) }
        var entries: [TarBuilder.Entry] = []
        var total = 0
        let base = folder.standardizedFileURL.path
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let full = file.standardizedFileURL.path
            var relative = full.hasPrefix(base) ? String(full.dropFirst(base.count)) : file.relativePath
            while relative.hasPrefix("/") { relative.removeFirst() }
            if relative.isEmpty || relative.split(separator: "/").last == ".DS_Store" { continue }
            guard let data = try? Data(contentsOf: file) else { throw Error.unreadable(relative) }
            total += data.count
            try checkSize(total)
            entries.append(.init(path: relative, bytes: data))
        }
        guard !entries.isEmpty else { throw Error.emptyFolder }
        entries.sort { $0.path < $1.path }
        return (entries, total)
    }

    static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    private static func checkSize(_ bytes: Int) throws {
        if bytes > maxBytes { throw Error.tooLarge(bytes: bytes) }
    }

    /// A picked URL from the Files app is security-scoped; a URL that
    /// isn't (our own temp dirs, tests) just runs the body.
    private static func withScopedAccess<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    static func describe(_ error: Swift.Error) -> String {
        switch error {
        case let known as Error: return known.errorDescription ?? "\(known)"
        case SwarmPublishService.PublishError.unreachable: return "The Swarm node isn't reachable."
        case SwarmPublishService.PublishError.malformedResponse: return "The node returned an unexpected response."
        case SwarmPublishService.PublishError.other(let detail): return "Publish failed: \(detail)"
        default: return "Publish failed: \(error.localizedDescription)"
        }
    }
}
