import Foundation
import OSLog
import UIKit
import WebKit

private let log = Logger(subsystem: "com.browser.Freedom", category: "AgentEngine")

/// Whichever of a result and a timeout comes first resumes the caller.
@MainActor
private final class ResumeOnce {
    private(set) var done = false
    var isDone: Bool { done }
    func claim() -> Bool {
        defer { done = true }
        return !done
    }
}

/// Reads and operates pages for the agent's browser tools. The page side
/// (agent-page.js, built from AgentEngine/page/) runs in the tab's own
/// content world, injected on first use per document, so the page's
/// scripts can't see or call it.
///
/// Each chat has its own tabs, as on desktop: the user's tabs it worked in
/// (adopted, never closed by the agent) and the tabs it opened, plus the
/// active one its tools act on. A new message from the user makes the tab
/// they're looking at the active one (`beginTurn`). Calls without a chat
/// (the test bench) use the visible tab.
@MainActor
final class AgentPageDriver {
    enum DriverError: LocalizedError {
        case noTab
        case privateTab
        case scriptMissing
        case badURL(String)
        case tabClosed
        case unknownTab
        case userTab
        case notOnScreen
        case screenshotFailed
        case staleVisualTarget
        case visualNotInteractable
        case visualClickOnly
        case pageTimeout(Int)
        case notDownloadable
        case notFileInput
        case uploadCancelled
        case uploadUnavailable
        case dialogOpen(String)
        case dialogGone
        case unknownFrame
        case staleFrame
        case opaqueFrame

        var errorDescription: String? {
            switch self {
            case .noTab: "No tab is open."
            case .privateTab: "The agent doesn't work in private tabs."
            case .scriptMissing: "The agent's page script is missing from the app."
            case .badURL(let reason): reason
            case .tabClosed: "TAB_UNAVAILABLE: the tab this chat was working in was closed. Use browser_list_tabs, browser_focus_tab or browser_create_tab."
            case .unknownTab: "TAB_NOT_FOUND: that isn't one of this chat's tabs. Use browser_list_tabs."
            case .userTab: "POLICY_DENIED: the agent can close only tabs it opened."
            case .notOnScreen: "The tab isn't on screen, so it can't be captured. Use browser_focus_tab first."
            case .screenshotFailed: "Freedom could not produce a page image."
            case .staleVisualTarget: "STALE_ELEMENT_REFERENCE: the visual target changed or expired; take a new screenshot and target it again."
            case .visualNotInteractable: "ELEMENT_NOT_INTERACTABLE: use a semantic control reference from browser_snapshot for this target."
            case .visualClickOnly: "Visual targets only support browser_click."
            case .dialogOpen(let summary): "DIALOG_OPEN: the page shows a dialog and waits for an answer (\(summary)). Read it with browser_get_dialog; answer it with browser_handle_dialog only if the task calls for it."
            case .dialogGone: "That dialog is no longer open. Use browser_get_dialog."
            case .notDownloadable: "DOWNLOAD_UNAVAILABLE: that element isn't a link Freedom can download. Use a download link from the snapshot."
            case .notFileInput: "ELEMENT_NOT_INTERACTABLE: that element isn't a file input."
            case .uploadCancelled: "FILE_UPLOAD_CANCELLED_BY_USER: the user didn't choose a file. Don't retry unless they ask again."
            case .uploadUnavailable: "File attachment is unavailable right now."
            case .unknownFrame: "FRAME_NOT_FOUND: that frame reference isn't known or the frame is gone. Use browser_list_frames."
            case .staleFrame: "STALE_FRAME_REFERENCE: the frame navigated or was removed. Use browser_list_frames and browser_read_frame again."
            case .opaqueFrame: "POLICY_DENIED: frames with an opaque origin can't be read."
            case .pageTimeout(let seconds): "TIMEOUT: the page didn't respond within \(seconds) s; it may be busy, stuck or reloading. Check it with browser_get_tab before trying again."
            }
        }
    }

    static let world = WKContentWorld.world(name: "FreedomAgent")

    private static let pageScript: String? = Bundle.main.url(forResource: "agent-page", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    private let tabs: TabStore
    private let defaults: UserDefaults
    /// Asks the user for a file for browser_upload (AgentService shows the
    /// picker on the agent's sheet): site and field label in, the file or nil out.
    var chooseFile: ((_ site: String, _ field: String) async -> AgentPickedFile?)?

    init(tabs: TabStore, defaults: UserDefaults = .standard) {
        self.tabs = tabs
        self.defaults = defaults
        chatTabs = defaults.data(forKey: Self.chatTabsKey).flatMap { try? JSONDecoder().decode([String: ChatTabs].self, from: $0) } ?? [:]
        chatDownloads = defaults.dictionary(forKey: Self.chatDownloadsKey) as? [String: [String]] ?? [:]
    }

    /// One call from the engine's `page` service.
    func handle(_ method: String, _ params: [String: Any]) async throws -> Any? {
        let chat = Self.chatKey(params["chatId"])
        switch method {
        case "tabs": return try await listTabs(chat)
        case "createTab": return try await createTab(chat, url: params["url"] as? String ?? "")
        case "focusTab": return try focusTab(chat, id: params["tabId"] as? String ?? "")
        case "closeTab": return try closeTab(chat, id: params["tabId"] as? String ?? "")
        case "listDownloads": return listDownloads(chat)
        default: break
        }
        let tab = try await workingTab(chat, opening: method == "navigate")
        switch method {
        case "getDialog":
            let dialog: Any = tab.pendingDialog.map { Self.describe($0) as Any } ?? NSNull()
            return ["dialog": dialog, "tab": state(of: tab)]
        case "handleDialog":
            guard let dialog = tab.pendingDialog, params["dialogRef"] as? String == Self.dialogRef(dialog) else { throw DriverError.dialogGone }
            let accept = (params["accept"] as? NSNumber)?.boolValue ?? false
            tab.answerDialog(accept: accept, text: dialog.kind == .prompt ? (params["promptText"] as? String ?? "") : nil)
            try? await Task.sleep(for: .milliseconds(120))
            return ["handled": true, "accepted": accept, "tab": state(of: tab)]
        case "tab", "stop", "navigate":
            break
        default:
            // The page's scripts are blocked while a dialog waits.
            if let dialog = tab.pendingDialog { throw DriverError.dialogOpen(Self.summary(dialog)) }
        }
        switch method {
        case "listFrames": return try await listFrames(tab)
        case "readFrame": return try await readFrame(tab, params)
        default: break
        }
        // A point from a screenshot (browser_target_point): only a click, and only while the view is unchanged.
        let ref = params["ref"] as? String ?? ""
        // An element of an embedded frame (browser_read_frame) is acted on in that frame.
        let frame = try frame(forRef: ref)
        if ref.hasPrefix("visual_") {
            switch method {
            case "describe": return await describeVisual(tab, ref: ref)
            case "click": return try await act(tab) { try await self.visualClick(tab, ref: ref) }
            case "type", "select", "press", "scroll": throw DriverError.visualClickOnly
            default: break
            }
        }
        switch method {
        case "tab":
            return state(of: tab)
        case "navigate":
            return try await navigate(tab, to: params["url"] as? String ?? "")
        case "stop":
            tab.stop()
            return ["stopped": true, "tab": state(of: tab)]
        #if DEBUG
        case "debugLoadHTML":
            // Page checks: a test page of their own, without a server.
            tab.webView.loadHTMLString(params["html"] as? String ?? "", baseURL: URL(string: "https://agent-check.invalid/"))
            return ["loading": true]
        #endif
        case "screenshot":
            return try await screenshot(tab)
        case "targetPoint":
            return try await targetPoint(tab, params)
        case "download":
            return try await download(tab, chat: chat, ref: ref, in: frame)
        case "upload":
            return try await act(tab) { try await self.upload(tab, ref: ref, in: frame) }
        #if DEBUG
        case "debugUpload":
            // Page checks: the upload path with test bytes instead of the user's choice.
            return try await act(tab) { try await self.callPage(tab, "setFile", params.filter { $0.key != "chatId" }, in: frame) }
        #endif
        case "snapshot", "describe", "matches", "containsText":
            return try await callPage(tab, method, params.filter { $0.key != "chatId" }, in: frame)
        case "click", "type", "select", "press", "scroll":
            return try await act(tab) { try await self.callPage(tab, method, params.filter { $0.key != "chatId" }, in: frame) }
        default:
            throw AgentEngine.EngineError.tool("Unknown page method: \(method)")
        }
    }

    /// Runs an action and reports the tab afterwards, once the page had a moment to react
    /// (a link starting to load, a form submitting). An action that opened a dialog
    /// returns at once: the page's scripts wait for the answer.
    private func act(_ tab: BrowserTab, _ action: () async throws -> Any?) async throws -> Any? {
        let before = navigationCount(tab.webView)
        var result: [String: Any]
        do {
            result = try await action() as? [String: Any] ?? [:]
        } catch DriverError.dialogOpen {
            guard let dialog = tab.pendingDialog else { throw DriverError.dialogGone }
            return ["ok": true, "dialogOpened": Self.describe(dialog), "tab": state(of: tab),
                    "note": "The action opened a dialog; the page waits for its answer (browser_handle_dialog)."]
        }
        try? await Task.sleep(for: .milliseconds(120))
        if result["ok"] as? Bool != false {
            result["tab"] = state(of: tab)
            result["navigated"] = navigationCount(tab.webView) != before || tab.isLoading
        }
        return result
    }

    func state(of tab: BrowserTab) -> [String: Any] {
        [
            "tabId": Self.tabID(tab.recordID),
            "url": tab.displayURL?.absoluteString ?? tab.webView.url?.absoluteString ?? "",
            "title": tab.title,
            "loading": tab.isLoading,
            "webLoading": tab.webView.isLoading,
            "progress": (tab.webView.estimatedProgress * 100).rounded() / 100,
            "navigationId": navigationCount(tab.webView),
        ]
    }

    // MARK: - Chat tabs

    struct ChatTabs: Codable {
        /// The tab the chat's tools act on.
        var active: UUID?
        /// The user's tabs the chat worked in: never closed by the agent.
        var adopted: [UUID] = []
        /// The tabs the chat opened.
        var created: [UUID] = []

        var all: [UUID] { adopted + created }
    }

    private static let chatTabsKey = "agent.chatTabs"
    private var chatTabs: [String: ChatTabs]

    private func saveChatTabs() {
        if let data = try? JSONEncoder().encode(chatTabs) { defaults.set(data, forKey: Self.chatTabsKey) }
    }

    private static func chatKey(_ value: Any?) -> String? {
        switch value {
        case let number as NSNumber: number.stringValue
        case let string as String: string
        default: nil
        }
    }

    private static func tabID(_ id: UUID) -> String { id.uuidString.lowercased() }

    /// The user sent a message: the tab they're looking at becomes the chat's active tab.
    func beginTurn(chatID: Int) {
        guard let tab = tabs.activeTab else { return }
        let chat = String(chatID)
        var entry = chatTabs[chat] ?? ChatTabs()
        if !entry.all.contains(tab.recordID) { entry.adopted.append(tab.recordID) }
        entry.active = tab.recordID
        chatTabs[chat] = entry
        saveChatTabs()
        log.notice("[page] chat \(chat, privacy: .public) turn on tab \(Self.tabID(tab.recordID).prefix(8), privacy: .public); tabs \(entry.all.map { Self.tabID($0).prefix(8) }.joined(separator: ","), privacy: .public)")
    }

    func forget(chatID: Int) {
        chatTabs[String(chatID)] = nil
        saveChatTabs()
    }

    func forgetAll() {
        chatTabs = [:]
        saveChatTabs()
    }

    /// The tab a call acts on: the chat's active tab, or for a chat without one yet the
    /// user's visible tab (adopted).
    private func workingTab(_ chat: String?, opening: Bool) async throws -> BrowserTab {
        guard let chat else { return try usable(await visibleTab(opening: opening)) }
        var entry = chatTabs[chat] ?? ChatTabs()
        if let id = entry.active {
            if let tab = tabs.tab(for: id) { return try usable(tab) }
            entry.active = nil
            chatTabs[chat] = entry
            saveChatTabs()
            throw DriverError.tabClosed
        }
        let tab = try await visibleTab(opening: opening)
        if !entry.all.contains(tab.recordID) { entry.adopted.append(tab.recordID) }
        entry.active = tab.recordID
        chatTabs[chat] = entry
        saveChatTabs()
        log.notice("[page] chat \(chat, privacy: .public) adopted the visible tab \(Self.tabID(tab.recordID).prefix(8), privacy: .public)")
        return try usable(tab)
    }

    private func visibleTab(opening: Bool) async throws -> BrowserTab {
        // Right after launch the restored tab takes a moment to come up, and a run
        // the app was killed during resumes at once: give it a few seconds.
        var tab = tabs.activeTab
        for _ in 0..<50 where tab == nil && !opening {
            try? await Task.sleep(for: .milliseconds(100))
            tab = tabs.activeTab
        }
        guard let tab = tab ?? (opening ? tabs.activeTabOpeningIfNeeded() : nil) else { throw DriverError.noTab }
        return tab
    }

    private func usable(_ tab: BrowserTab) throws -> BrowserTab {
        guard !tab.isPrivate else { throw DriverError.privateTab }
        observeNavigations(tab.webView)
        return tab
    }

    private func listTabs(_ chat: String?) async throws -> [String: Any] {
        guard let chat else {
            let tab = try usable(await visibleTab(opening: false))
            return ["activeTabId": Self.tabID(tab.recordID), "tabs": [listed(tab, active: true, openedByAgent: false)]]
        }
        var entry = chatTabs[chat] ?? ChatTabs()
        // Tabs the user closed drop out.
        entry.adopted.removeAll { tabs.tab(for: $0) == nil }
        entry.created.removeAll { tabs.tab(for: $0) == nil }
        if let active = entry.active, !entry.all.contains(active) { entry.active = nil }
        chatTabs[chat] = entry
        saveChatTabs()
        let items = entry.all.compactMap { id in
            tabs.tab(for: id).map { listed($0, active: id == entry.active, openedByAgent: entry.created.contains(id)) }
        }
        return ["activeTabId": entry.active.map(Self.tabID) ?? NSNull(), "tabs": items]
    }

    private func listed(_ tab: BrowserTab, active: Bool, openedByAgent: Bool) -> [String: Any] {
        var item = state(of: tab)
        item["active"] = active
        item["shown"] = tab.recordID == tabs.activeRecordID
        item["openedByAgent"] = openedByAgent
        if tab.isPrivate { item["private"] = true }
        return item
    }

    private func createTab(_ chat: String?, url input: String) async throws -> [String: Any] {
        let target = try Self.parse(input)
        let id = tabs.newTab(isPrivate: false)
        // Brings the page up over the tab overview, as for a link from another app.
        tabs.externalOpenToken += 1
        guard let tab = tabs.tab(for: id) else { throw DriverError.noTab }
        if let chat {
            var entry = chatTabs[chat] ?? ChatTabs()
            entry.created.append(id)
            entry.active = id
            chatTabs[chat] = entry
            saveChatTabs()
        }
        let result = try await navigate(try usable(tab), to: target)
        return ["created": true, "tabId": Self.tabID(id)].merging(result) { first, _ in first }
    }

    private func focusTab(_ chat: String?, id raw: String) throws -> [String: Any] {
        guard let chat, let id = UUID(uuidString: raw), var entry = chatTabs[chat], entry.all.contains(id),
              let tab = tabs.tab(for: id) else { throw DriverError.unknownTab }
        _ = try usable(tab)
        tabs.activate(id)
        tabs.externalOpenToken += 1
        entry.active = id
        chatTabs[chat] = entry
        saveChatTabs()
        return ["focused": true, "tab": state(of: tab)]
    }

    private func closeTab(_ chat: String?, id raw: String) throws -> [String: Any] {
        guard let chat, let id = UUID(uuidString: raw), var entry = chatTabs[chat], entry.all.contains(id),
              tabs.tab(for: id) != nil else { throw DriverError.unknownTab }
        guard entry.created.contains(id) else { throw DriverError.userTab }
        tabs.close(id)
        entry.created.removeAll { $0 == id }
        if entry.active == id { entry.active = entry.created.last ?? entry.adopted.last }
        chatTabs[chat] = entry
        saveChatTabs()
        return ["closed": true, "tabId": Self.tabID(id), "activeTabId": entry.active.map(Self.tabID) ?? NSNull()]
    }

    // MARK: - Navigation

    private static let allowedSchemes: Set<String> = ["http", "https", "bzz", "ipfs", "ipns", "ens"]

    private static func parse(_ input: String) throws -> BrowserURL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // A bare name (vitalik.eth, name.tez) is fine: the address bar opens it the same way.
        if !trimmed.contains("://"), let target = BrowserURL.parse(trimmed) {
            switch target {
            case .ens, .tez: return target
            default: break
            }
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else {
            throw DriverError.badURL("Use an absolute http, https, bzz, ipfs, ipns or ens URL.")
        }
        guard url.user == nil, url.password == nil else { throw DriverError.badURL("URLs with embedded credentials aren't allowed.") }
        guard let target = BrowserURL.parse(trimmed) else { throw DriverError.badURL("That isn't a URL Freedom can open.") }
        return target
    }

    private func navigate(_ tab: BrowserTab, to input: String) async throws -> [String: Any] {
        try await navigate(tab, to: try Self.parse(input))
    }

    private func navigate(_ tab: BrowserTab, to target: BrowserURL) async throws -> [String: Any] {
        let before = navigationCount(tab.webView)
        tab.navigate(to: target)
        // Report once loading has started (or the name is resolving), not when it ends: browser_wait does that.
        for _ in 0..<20 where navigationCount(tab.webView) == before && !tab.isLoading {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return ["navigating": true, "tab": state(of: tab)]
    }

    /// Navigation counters per web view: bumped whenever its URL changes,
    /// including in-page navigations, so waits and results can tell.
    private var navigations: [ObjectIdentifier: (count: Int, observation: NSKeyValueObservation)] = [:]

    private func observeNavigations(_ webView: WKWebView) {
        let id = ObjectIdentifier(webView)
        guard navigations[id] == nil else { return }
        // KVO on a web view arrives on the main thread (as in BrowserTab).
        let observation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.navigations[id]?.count += 1 }
        }
        navigations[id] = (0, observation)
    }

    private func navigationCount(_ webView: WKWebView) -> Int { navigations[ObjectIdentifier(webView)]?.count ?? 0 }

    // MARK: - Screenshots and visual targets (desktop's visual-targets.js)

    /// What a screenshot showed: valid for a visual target while the tab,
    /// its document and the page's viewport and DOM are unchanged.
    private struct Capture {
        let tabID: UUID
        let navigation: Int
        let viewport: [String: Double]
        let expires: Date
    }

    private struct VisualTarget {
        let capture: Capture
        let point: CGPoint
        let label: String
    }

    private var captures: [(ref: String, capture: Capture)] = []
    private var targets: [(ref: String, target: VisualTarget)] = []

    private func viewport(_ tab: BrowserTab) async throws -> [String: Double] {
        let raw = try await callPage(tab, "viewport", [:]) as? [String: Any] ?? [:]
        return raw.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    /// The page's viewport (its CSS layout viewport) in the web view's coordinates.
    private static func viewportRect(_ webView: WKWebView, _ viewport: [String: Double]) -> CGRect {
        let zoom = webView.scrollView.zoomScale
        let inset = webView.scrollView.adjustedContentInset
        let width = (viewport["width"] ?? 0) * zoom
        let height = (viewport["height"] ?? 0) * zoom
        return CGRect(x: inset.left, y: inset.top, width: width, height: height).intersection(webView.bounds)
    }

    private func screenshot(_ tab: BrowserTab) async throws -> [String: Any] {
        let webView = tab.webView
        guard webView.window != nil else { throw DriverError.notOnScreen }
        let before = try await viewport(tab)
        let rect = Self.viewportRect(webView, before)
        guard rect.width > 0, rect.height > 0 else { throw DriverError.screenshotFailed }
        let config = WKSnapshotConfiguration()
        config.rect = rect
        let image: UIImage = try await Self.withTimeout(10) {
            try await withCheckedThrowingContinuation { continuation in
                webView.takeSnapshot(with: config) { image, error in
                    if let image { continuation.resume(returning: image) } else { continuation.resume(throwing: error ?? DriverError.screenshotFailed) }
                }
            }
        }
        let after = try await viewport(tab)
        // The image is the viewport in CSS pixels, scaled up to at most 2× and 1400 pixels on its long side.
        let cssWidth = before["width"] ?? rect.width, cssHeight = before["height"] ?? rect.height
        let factor = min(2, 1400 / max(cssWidth, cssHeight))
        let size = CGSize(width: (cssWidth * factor).rounded(), height: (cssHeight * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = scaled.jpegData(compressionQuality: 0.8) else { throw DriverError.screenshotFailed }
        var result: [String: Any] = [
            "mediaType": "image/jpeg",
            "base64": jpeg.base64EncodedString(),
            "width": Int(size.width),
            "height": Int(size.height),
            "tab": state(of: tab),
        ]
        // Coordinates are only bound to a viewport that held still while it was captured, unzoomed.
        let still = before == after && before["scale"] == 1 && (before["offsetX"] ?? 0) == 0 && (before["offsetY"] ?? 0) == 0
        if still {
            let ref = "capture_\(UUID().uuidString.lowercased())"
            captures.append((ref, Capture(tabID: tab.recordID, navigation: navigationCount(webView), viewport: before, expires: Date().addingTimeInterval(300))))
            if captures.count > 4 { captures.removeFirst(captures.count - 4) }
            result["captureRef"] = ref
        }
        #if DEBUG
        try? jpeg.write(to: FileManager.default.temporaryDirectory.appending(path: "agent-screenshot.jpg"))
        #endif
        log.notice("[page] screenshot \(Int(size.width))×\(Int(size.height)), \(jpeg.count / 1024) KB\(still ? "" : ", viewport moved", privacy: .public)")
        return result
    }

    private func stillValid(_ capture: Capture, _ tab: BrowserTab) async -> Bool {
        guard capture.tabID == tab.recordID, capture.expires > Date(), capture.navigation == navigationCount(tab.webView),
              let now = try? await viewport(tab) else { return false }
        return now == capture.viewport
    }

    private func targetPoint(_ tab: BrowserTab, _ params: [String: Any]) async throws -> [String: Any] {
        let captureRef = params["captureRef"] as? String ?? ""
        let x = (params["x"] as? NSNumber)?.doubleValue ?? -1, y = (params["y"] as? NSNumber)?.doubleValue ?? -1
        guard (0..<1).contains(x), (0..<1).contains(y),
              let capture = captures.first(where: { $0.ref == captureRef })?.capture,
              await stillValid(capture, tab) else { throw DriverError.staleVisualTarget }
        let point = CGPoint(x: x * (capture.viewport["width"] ?? 0), y: y * (capture.viewport["height"] ?? 0))
        let ref = "visual_\(UUID().uuidString.lowercased())"
        let hit = try await callPage(tab, "visualTarget", ["ref": ref, "x": point.x, "y": point.y, "create": true]) as? [String: Any]
        guard hit?["ok"] as? Bool == true else { throw DriverError.visualNotInteractable }
        let label = "Visual point (\(Int(x * 100))%, \(Int(y * 100))%); effect unknown"
        targets.append((ref, VisualTarget(capture: capture, point: point, label: label)))
        if targets.count > 8 { targets.removeFirst(targets.count - 8) }
        return ["ref": ref, "label": label, "supportedActions": ["click"], "singleUse": true]
    }

    /// The visual target, if the page still looks the way it was captured and the
    /// same element is under its point.
    private func liveTarget(_ tab: BrowserTab, ref: String) async -> VisualTarget? {
        guard let target = targets.first(where: { $0.ref == ref })?.target, await stillValid(target.capture, tab) else { return nil }
        let hit = try? await callPage(tab, "visualTarget", ["ref": ref, "x": target.point.x, "y": target.point.y, "create": false]) as? [String: Any]
        return hit?["ok"] as? Bool == true ? target : nil
    }

    private func describeVisual(_ tab: BrowserTab, ref: String) async -> [String: Any] {
        guard let target = await liveTarget(tab, ref: ref) else { return ["ok": false, "reason": "changed"] }
        return ["ok": true, "label": target.label, "effect": "", "navigationTarget": "", "formPayloadFingerprint": "", "visual": true]
    }

    private func visualClick(_ tab: BrowserTab, ref: String) async throws -> Any? {
        guard let target = await liveTarget(tab, ref: ref) else { throw DriverError.staleVisualTarget }
        targets.removeAll { $0.ref == ref }
        return try await callPage(tab, "visualClick", ["ref": ref, "x": target.point.x, "y": target.point.y])
    }

    // MARK: - Page script

    private static let installSentinel = "__freedom_agent_needs_page_script"

    /// `work`'s result, or `pageTimeout` after `seconds`: a page that hangs (a busy
    /// script, a process coming back from a crash) must not hold a tool forever.
    /// WebKit can't cancel a script call; a late result is dropped.
    private static func withTimeout<T>(
        _ seconds: Int,
        interrupt: (@MainActor () -> Error?)? = nil,
        _ work: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            // A page dialog blocks the page's scripts: stop waiting when one appears.
            if let interrupt {
                Task { @MainActor in
                    while !once.isDone {
                        if let error = interrupt(), once.claim() {
                            continuation.resume(throwing: error)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
            Task { @MainActor in
                do {
                    let value = try await work()
                    if once.claim() { continuation.resume(returning: value) }
                } catch {
                    if once.claim() { continuation.resume(throwing: error) }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() {
                    log.error("[page] no answer from the page within \(seconds) s")
                    continuation.resume(throwing: DriverError.pageTimeout(seconds))
                }
            }
        }
    }

    private func callPage(_ tab: BrowserTab, _ method: String, _ params: [String: Any], in frame: WKFrameInfo? = nil) async throws -> Any? {
        try await Self.withTimeout(20, interrupt: { tab.pendingDialog.map { DriverError.dialogOpen(Self.summary($0)) } }) {
            try await self.callPageUnbounded(tab, method, params, in: frame)
        }
    }

    // MARK: - Downloads and uploads

    private static let chatDownloadsKey = "agent.chatDownloads"
    /// The downloads each chat started (DownloadManager item IDs).
    private var chatDownloads: [String: [String]]

    private static let downloadableSchemes: Set<String> = ["http", "https", "bzz", "ipfs", "ipns", "data"]

    /// browser_download: the link's target through Freedom's download manager (after the approval).
    private func download(_ tab: BrowserTab, chat: String?, ref: String, in frame: WKFrameInfo?) async throws -> [String: Any] {
        let described = try await callPage(tab, "describe", ["ref": ref, "action": "download", "key": ""], in: frame) as? [String: Any] ?? [:]
        guard described["ok"] as? Bool == true else { return described }
        guard let target = described["navigationTarget"] as? String, let url = URL(string: target),
              let scheme = url.scheme?.lowercased(), Self.downloadableSchemes.contains(scheme) else { throw DriverError.notDownloadable }
        let download = await tab.webView.startDownload(using: URLRequest(url: url))
        let manager = DownloadManager.shared
        let id = manager.adopt(download, sourceURL: url, mimeType: nil, from: tab.webView, ephemeral: tab.isPrivate)
        if let chat {
            chatDownloads[chat, default: []].append(id.uuidString)
            defaults.set(chatDownloads, forKey: Self.chatDownloadsKey)
        }
        // Small files finish at once; a big one reports progress and stays in Downloads.
        for _ in 0..<240 {
            if manager.item(id: id)?.isActive == false { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return manager.item(id: id).map(receipt) ?? ["downloadId": id.uuidString.lowercased(), "state": "unknown"]
    }

    private func listDownloads(_ chat: String?) -> [String: Any] {
        let ids = chat.flatMap { chatDownloads[$0] } ?? []
        let items = ids.compactMap(UUID.init(uuidString:)).compactMap { DownloadManager.shared.item(id: $0) }
        return ["downloads": items.map(receipt)]
    }

    private func receipt(_ item: DownloadItem) -> [String: Any] {
        let state: String = switch item.state {
        case .inProgress: "inProgress"
        case .paused: "paused"
        case .completed: "completed"
        case .failed(let message): "failed: \(message)"
        case .cancelled: "cancelled"
        }
        var receipt: [String: Any] = [
            "downloadId": item.id.uuidString.lowercased(),
            "filename": item.filename,
            "state": state,
            "bytes": item.bytesReceived,
            "available": item.state == .completed && FileManager.default.fileExists(atPath: DownloadManager.shared.fileURL(for: item).path),
        ]
        if let total = item.totalBytes { receipt["totalBytes"] = total }
        if let mime = item.mimeType { receipt["mimeType"] = mime }
        return receipt
    }

    /// browser_upload: the user chooses the file (after the approval), the page script puts it into the input.
    private func upload(_ tab: BrowserTab, ref: String, in frame: WKFrameInfo?) async throws -> Any? {
        let described = try await callPage(tab, "describe", ["ref": ref, "action": "upload", "key": ""], in: frame) as? [String: Any] ?? [:]
        guard described["ok"] as? Bool == true else { return described }
        guard described["effect"] as? String == "file_upload" else { throw DriverError.notFileInput }
        guard let chooseFile else { throw DriverError.uploadUnavailable }
        let site = frame.map { $0.securityOrigin.host } ?? tab.webView.url?.host() ?? "this page"
        guard let file = await chooseFile(site, described["label"] as? String ?? "") else { throw DriverError.uploadCancelled }
        return try await callPage(tab, "setFile", ["ref": ref, "base64": file.data.base64EncodedString(), "name": file.name, "type": file.mimeType], in: frame)
    }

    // MARK: - Embedded frames

    /// Frames read so far, by the key in their references (`frame_<key>`,
    /// `frame_element_<key>_…`).
    private var frames: [String: WKFrameInfo] = [:]

    private static let frameProbe = """
    const token = (globalThis.__freedomAgentFrameToken ||= Array.from(crypto.getRandomValues(new Uint8Array(4)), (b) => b.toString(16).padStart(2, "0")).join(""));
    return JSON.stringify({ token, url: location.href, origin: location.origin, title: document.title });
    """

    /// The frame's document: its key (new for each document), URL and origin; nil when the frame is gone.
    private func probe(_ tab: BrowserTab, _ frame: WKFrameInfo) async -> [String: String]? {
        let raw = try? await Self.withTimeout(3) {
            try await tab.webView.callAsyncJavaScript(Self.frameProbe, arguments: [:], in: frame, contentWorld: Self.world)
        }
        guard let json = raw as? String, let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: String]
    }

    private func listFrames(_ tab: BrowserTab) async throws -> [String: Any] {
        let pageOrigin = tab.webView.url.flatMap { url in url.scheme.map { "\($0)://\(url.host() ?? "")" } } ?? ""
        var seen = Set<String>()
        var listed: [[String: Any]] = []
        for frame in tab.subframes.reversed() where listed.count < 24 {
            guard let info = await probe(tab, frame), let key = info["token"], !seen.contains(key) else { continue }
            seen.insert(key)
            frames[key] = frame
            let origin = info["origin"] ?? ""
            var item: [String: Any] = ["frameRef": "frame_\(key)", "url": info["url"] ?? "", "origin": origin, "title": info["title"] ?? ""]
            if origin == "null" { item["opaque"] = true }
            if origin == pageOrigin { item["sameOriginAsPage"] = true }
            listed.append(item)
        }
        return ["frames": listed, "tab": state(of: tab)]
    }

    private func readFrame(_ tab: BrowserTab, _ params: [String: Any]) async throws -> [String: Any] {
        let raw = params["frameRef"] as? String ?? ""
        let key = raw.hasPrefix("frame_") ? String(raw.dropFirst("frame_".count)) : raw
        guard let frame = frames[key] else { throw DriverError.unknownFrame }
        guard let info = await probe(tab, frame) else { throw DriverError.unknownFrame }
        guard info["token"] == key else { throw DriverError.staleFrame }
        guard info["origin"] != "null" else { throw DriverError.opaqueFrame }
        var options = params["options"] as? [String: Any] ?? [:]
        options["refPrefix"] = "frame_element_\(key)"
        let result = try await callPage(tab, "snapshot", ["options": options], in: frame)
        return ["ok": true, "frameRef": "frame_\(key)", "url": info["url"] ?? "", "origin": info["origin"] ?? "", "result": result ?? NSNull()]
    }

    /// The frame a reference belongs to: nil for the page's own (and its same-origin frames).
    private func frame(forRef ref: String) throws -> WKFrameInfo? {
        guard let range = ref.range(of: "frame_element_") else { return nil }
        let key = String(ref[range.upperBound...].prefix(8))
        guard let frame = frames[key] else { throw DriverError.unknownFrame }
        return frame
    }

    // MARK: - Dialogs

    private static func dialogRef(_ dialog: BrowserTab.PageDialog) -> String { "dialog_\(dialog.id.uuidString.lowercased())" }

    private static func describe(_ dialog: BrowserTab.PageDialog) -> [String: Any] {
        var info: [String: Any] = ["dialogRef": dialogRef(dialog), "type": dialog.kind.rawValue, "message": dialog.message, "origin": dialog.host, "mainFrame": dialog.isMainFrame]
        if dialog.kind == .prompt { info["defaultPrompt"] = dialog.defaultText ?? "" }
        return info
    }

    private static func summary(_ dialog: BrowserTab.PageDialog) -> String {
        "\(dialog.kind.rawValue) from \(dialog.host): “\(dialog.message.prefix(120))”"
    }

    private func callPageUnbounded(_ tab: BrowserTab, _ method: String, _ params: [String: Any], in frame: WKFrameInfo?) async throws -> Any? {
        let webView = tab.webView
        let body = """
        const page = globalThis.__freedomAgentPage;
        if (!page) return "\(Self.installSentinel)";
        return await page.call(method, args);
        """
        let arguments: [String: Any] = ["method": method, "args": params]
        var result = try await webView.callAsyncJavaScript(body, arguments: arguments, in: frame, contentWorld: Self.world)
        if result as? String == Self.installSentinel {
            guard let script = Self.pageScript else { throw DriverError.scriptMissing }
            _ = try await webView.callAsyncJavaScript(script + "\nreturn true;", arguments: [:], in: frame, contentWorld: Self.world)
            let host = frame.map { $0.securityOrigin.host } ?? webView.url?.host() ?? "?"
            log.notice("[page] installed the page script on \(host, privacy: .public)\(frame == nil ? "" : " (frame)", privacy: .public)")
            result = try await webView.callAsyncJavaScript(body, arguments: arguments, in: frame, contentWorld: Self.world)
        }
        guard let json = result as? String, let data = json.data(using: .utf8) else { return result }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
