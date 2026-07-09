import Foundation
import UIKit
import WebKit

/// `OpenLVSessionEngine` implementation #1: a hidden 1×1 WKWebView
/// running the upstream openlv JS SDK (`openlv.esm.js`, the same bundle
/// the desktop browser vendors) behind a thin shim (`OpenLVShim.js`)
/// that mirrors the desktop bridge page but round-trips requests over
/// `window.webkit.messageHandlers` instead of `window.ethereum`.
///
/// The WKWebView supplies what the protocol needs and CryptoKit/iOS
/// lacks a drop-in for (WebRTC transport, XSalsa20-Poly1305 envelopes,
/// MQTT-over-WebSocket signaling) — a native Swift engine can replace
/// this behind the same seam once the upstream spec stabilizes.
///
/// The engine attaches its hidden webView to the key window on
/// `start` and detaches on `stop` — detached WKWebViews get their
/// timers and network throttled, which stalls the signaling handshake.
/// Consumers never touch the view, so they stay protocol-only and a
/// native engine can replace this one without integration changes.
/// Foreground-only by design: signing is a foreground interaction.
@MainActor
final class WebViewOpenLVEngine: NSObject, OpenLVSessionEngine {
    static let messageHandlerName = "openlv"

    enum Error: Swift.Error {
        case shellFailedToLoad(String)
    }

    /// Hidden host for the JS runtime — 1×1, hidden, attached to the key
    /// window while a session runs. Internal (not on the protocol) so
    /// tests can reach the page; production consumers must not use it.
    let webView: WKWebView

    var requestHandler: ((_ method: String, _ params: [Any]) async -> OpenLVResponse)?
    var statusHandler: ((OpenLVEngineStatus) -> Void)?

    private let replies: BridgeReplyChannel
    private var isReady = false
    private var loadFailure: String?
    private var readyWaiters: [UUID: (continuation: CheckedContinuation<Void, Swift.Error>, timeout: Task<Void, Never>)] = [:]

    /// `WKUserContentController.add(_:name:)` retains its handler and the
    /// engine retains the webView (→ configuration → controller), so the
    /// handler must be a weak proxy or the engine could never deinit.
    private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
        private weak var engine: WebViewOpenLVEngine?
        init(engine: WebViewOpenLVEngine) { self.engine = engine }
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == WebViewOpenLVEngine.messageHandlerName else { return }
            engine?.handleShimMessage(message.body)
        }
    }

    override init() {
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1, height: 1),
            configuration: configuration
        )
        webView.isHidden = true
        replies = BridgeReplyChannel(jsGlobal: "__freedomOpenLV", webView: webView)
        super.init()
        configuration.userContentController.add(
            WeakMessageHandler(engine: self), name: Self.messageHandlerName
        )
        loadShell()
    }

    private func loadShell() {
        guard let url = Bundle.main.url(forResource: "OpenLVShell", withExtension: "html") else {
            assertionFailure("OpenLVShell.html missing from app bundle")
            failLoad("OpenLVShell.html missing from app bundle")
            return
        }
        // file:// is a secure context (the SDK needs crypto.subtle). ES
        // modules don't load from file:// (opaque origin), which is why
        // the shell uses classic scripts + the IIFE SDK flavor.
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    // MARK: - OpenLVSessionEngine

    func start(uri: String) async throws {
        attachToWindowIfNeeded()
        try await waitUntilReady()
        replies.emit(event: "start", data: uri)
    }

    func stop() {
        if isReady {
            replies.emit(event: "stop", data: NSNull())
        }
        webView.removeFromSuperview()
    }

    /// Unattached WKWebViews are throttled; host the 1×1 view in the key
    /// window for the session's lifetime. Signing is always a foreground
    /// interaction, so a key window exists whenever `start` runs.
    private func attachToWindowIfNeeded() {
        guard webView.superview == nil else { return }
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?
            .addSubview(webView)
    }

    // MARK: - Readiness

    /// Resolves once the shell page has evaluated the shim module (it
    /// posts `ready`); throws if the shell can't load or the module never
    /// signals within `timeout`.
    func waitUntilReady(timeout: TimeInterval = 10) async throws {
        if isReady { return }
        if let loadFailure { throw Error.shellFailedToLoad(loadFailure) }

        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.resumeWaiter(
                    id: id,
                    with: .failure(Error.shellFailedToLoad("shim never signalled ready"))
                )
            }
            readyWaiters[id] = (continuation, timeoutTask)
        }
    }

    private func resumeWaiter(id: UUID, with result: Result<Void, Swift.Error>) {
        guard let waiter = readyWaiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(with: result)
    }

    private func resumeAllWaiters(with result: Result<Void, Swift.Error>) {
        for id in Array(readyWaiters.keys) {
            resumeWaiter(id: id, with: result)
        }
    }

    private func failLoad(_ message: String) {
        loadFailure = message
        resumeAllWaiters(with: .failure(Error.shellFailedToLoad(message)))
        statusHandler?(.failed(message))
    }

    // MARK: - Shim messages

    private func handleShimMessage(_ body: Any) {
        guard let message = OpenLVShimMessage.parse(body) else { return }
        switch message {
        case .ready:
            isReady = true
            resumeAllWaiters(with: .success(()))
        case .status(let status):
            // A failure before the shim ever signalled ready is a boot
            // failure (script didn't load / threw) — fail waiters now
            // rather than letting them run into the timeout.
            if case .failed(let message) = status, !isReady {
                failLoad(message)
            } else {
                statusHandler?(status)
            }
        case .request(let id, let method, let params):
            Task { [weak self] in
                guard let self else { return }
                let response = await self.requestHandler?(method, params)
                    ?? .error(code: -32603, message: "Wallet endpoint has no request handler.")
                self.send(response, forRequest: id)
            }
        }
    }

    private func send(_ response: OpenLVResponse, forRequest id: Int) {
        switch response {
        case .result(let value):
            replies.reply(id: id, result: value)
        case .error(let code, let message):
            replies.reply(id: id, errorObject: ["code": code, "message": message])
        }
    }
}
