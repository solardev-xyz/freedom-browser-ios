import Foundation
import OSLog
import WebKit

private let log = Logger(subsystem: "com.browser.Freedom", category: "AgentEngine")

/// Pi's agent loop (AgentEngine/, bundled into Resources/agent-engine) running
/// in a hidden WKWebView. The engine reaches the app through the
/// `freedomAgent` message handler: tool calls, events and console output.
/// The app drives it with `command(_:_:)`.
final class AgentEngine: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    enum EngineError: LocalizedError {
        case notStarted
        case bootTimedOut
        case tool(String)

        var errorDescription: String? {
            switch self {
            case .notStarted: "The agent engine isn't running."
            case .bootTimedOut: "The agent engine didn't start within 15 s."
            case .tool(let message): message
            }
        }
    }

    /// Engine events (`text`, `tool_start`, `tool_end`, `done`, …) as JSON objects.
    var onEvent: (([String: Any]) -> Void)?
    /// The engine's web content process died (WebKit crashed or iOS reclaimed
    /// it): everything in it is gone, so the owner starts a new engine, and the
    /// durable agent continues from its database.
    var onTerminated: (() -> Void)?
    /// Backs the `read_page` tool.
    var readPage: (() async throws -> [String: Any])?
    /// Backs the browser tools (the `page` service). A reference, not a
    /// closure: with this target's concurrency settings, converting an async
    /// closure with arguments for this property miscompiled (Swift 6.2: the
    /// thunk passed garbage for the method string, crashing in `handle`).
    var pageDriver: AgentPageDriver?
    /// The agent's wallet tool (`wallet_transfer`), a reference like `pageDriver`.
    var walletDriver: AgentWalletDriver?
    /// The chats' attached files, for the attachment tools.
    var attachmentStore: AgentAttachmentStore?
    /// Freedom's nodes, for the node and Swarm tools.
    var nodeDriver: AgentNodeDriver?

    private(set) var webView: WKWebView?
    private var readyWaiter: CheckedContinuation<Void, Error>?
    /// The engine's storage (the `sql` service).
    private let database = AgentDatabase()

    /// Loads the engine and waits for its `ready` event. Returns the boot time in ms.
    func start() async throws -> Int {
        let t0 = Date()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(AgentEngineSchemeHandler(), forURLScheme: AgentEngineSchemeHandler.scheme)
        config.userContentController.addScriptMessageHandler(WeakReplyHandler(self), contentWorld: .page, name: "freedomAgent")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        webView.navigationDelegate = self
        #if DEBUG
        webView.isInspectable = true
        #endif
        self.webView = webView
        // iOS WebKit counts a web view outside any window as a hidden page and
        // throttles its timers, which Pi's streaming and commits run on. So the
        // engine sits in the app's window, invisible and untouchable.
        // FREEDOM_DEBUG_AGENT_DETACHED=1 leaves it out, to compare.
        if ProcessInfo.processInfo.environment["FREEDOM_DEBUG_AGENT_DETACHED"] != "1", let window = Self.hostWindow() {
            webView.alpha = 0
            webView.isUserInteractionEnabled = false
            webView.accessibilityElementsHidden = true
            window.insertSubview(webView, at: 0)
            log.notice("[engine] in window \(String(describing: type(of: window)), privacy: .public) key=\(window.isKeyWindow) hidden=\(window.isHidden) level=\(window.windowLevel.rawValue)")
        } else {
            log.error("[engine] no window to sit in: timers will be throttled")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readyWaiter = continuation
            webView.load(URLRequest(url: AgentEngineSchemeHandler.engineURL))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.readyWaiter?.resume(throwing: EngineError.bootTimedOut)
                self?.readyWaiter = nil
            }
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        log.notice("[engine] ready in \(ms) ms")
        #if DEBUG
        // For crash-recovery tests: the process to kill (private WebKit key, DEBUG only).
        if let pid = webView.value(forKey: "_webProcessIdentifier") as? Int { log.notice("[engine] web process pid \(pid)") }
        #endif
        return ms
    }

    func stop() {
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.removeFromSuperview()
        webView = nil
        database.close()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.error("[engine] its web content process died")
        readyWaiter?.resume(throwing: EngineError.notStarted)
        readyWaiter = nil
        onTerminated?()
    }

    private static func hostWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    /// Runs `window.__freedomAgent.command(name, params)` in the engine.
    func command(_ name: String, _ params: [String: Any] = [:]) async throws -> Any? {
        guard let webView else { throw EngineError.notStarted }
        return try await webView.callAsyncJavaScript(
            "return await window.__freedomAgent.command(name, params)",
            arguments: ["name": name, "params": params],
            in: nil,
            contentWorld: .page
        )
    }

    // MARK: - Engine → app

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any],
              let service = body["service"] as? String else {
            replyHandler(nil, "Malformed message")
            return
        }
        let method = body["method"] as? String ?? ""
        switch service {
        case "event":
            let event = body["params"] as? [String: Any] ?? [:]
            if event["type"] as? String == "ready" {
                readyWaiter?.resume()
                readyWaiter = nil
            }
            onEvent?(event)
            replyHandler(nil, nil)
        case "log":
            let text = body["params"] as? String ?? ""
            if method == "error" || method == "warn" {
                log.error("[engine:\(method, privacy: .public)] \(text, privacy: .public)")
            } else {
                log.notice("[engine:\(method, privacy: .public)] \(text, privacy: .public)")
            }
            replyHandler(nil, nil)
        case "sql":
            let operation: AgentDatabase.Operation
            do {
                operation = try AgentDatabase.Operation(method: method, params: body["params"] as? [String: Any] ?? [:])
            } catch {
                replyHandler(nil, error.localizedDescription)
                return
            }
            database.perform(operation) { result in
                Task { @MainActor in
                    switch result {
                    case .success(let reply): replyHandler(reply.value, nil)
                    case .failure(let error): replyHandler(nil, error.localizedDescription)
                    }
                }
            }
        case "page":
            guard let pageDriver else {
                replyHandler(nil, "The browser tools aren't available")
                return
            }
            let params = body["params"] as? [String: Any] ?? [:]
            Task {
                do {
                    replyHandler(try await pageDriver.handle(method, params), nil)
                } catch {
                    replyHandler(nil, error.localizedDescription)
                }
            }
        case "nodes":
            guard let nodeDriver else {
                replyHandler(nil, "The node tools aren't available")
                return
            }
            let params = body["params"] as? [String: Any] ?? [:]
            Task {
                do {
                    replyHandler(try await nodeDriver.handle(method, params), nil)
                } catch {
                    replyHandler(nil, error.localizedDescription)
                }
            }
        case "attachments":
            guard let attachmentStore else {
                replyHandler(nil, "Attachments aren't available")
                return
            }
            let params = body["params"] as? [String: Any] ?? [:]
            Task {
                do {
                    replyHandler(try await attachmentStore.handle(method, params), nil)
                } catch {
                    replyHandler(nil, error.localizedDescription)
                }
            }
        case "wallet":
            guard let walletDriver else {
                replyHandler(nil, "The wallet tools aren't available")
                return
            }
            let params = body["params"] as? [String: Any] ?? [:]
            Task {
                do {
                    replyHandler(try await walletDriver.handle(method, params), nil)
                } catch {
                    replyHandler(nil, error.localizedDescription)
                }
            }
        case "tool":
            guard method == "readPage", let readPage else {
                replyHandler(nil, "Unknown tool: \(method)")
                return
            }
            Task {
                do {
                    replyHandler(try await readPage(), nil)
                } catch {
                    replyHandler(nil, error.localizedDescription)
                }
            }
        default:
            replyHandler(nil, "Unknown service: \(service)")
        }
    }
}

/// WKUserContentController retains its handlers; this keeps it from
/// retaining the engine.
private final class WeakReplyHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var target: (any WKScriptMessageHandlerWithReply)?

    init(_ target: any WKScriptMessageHandlerWithReply) { self.target = target }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let target else {
            replyHandler(nil, "The agent engine is gone")
            return
        }
        target.userContentController(userContentController, didReceive: message, replyHandler: replyHandler)
    }
}
