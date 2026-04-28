import Foundation
import WebKit

/// Per-`BrowserTab` `window.swarm` bridge. Origin identity is derived
/// from `tab.displayURL` at every message receipt — the JS side never
/// supplies it. Non-interactive methods (`swarm_getCapabilities`,
/// `swarm_listFeeds`) go through `SwarmRouter`; `swarm_requestAccess`
/// short-circuits here so it can park an `ApprovalRequest` continuation.
@MainActor
final class SwarmBridge: NSObject, WKScriptMessageHandler {
    static let messageHandlerName = "freedomSwarm"
    /// Surfaces returned in `swarm_requestAccess.result.capabilities`
    /// — a stable "what this provider can do" list. Grows when WP6
    /// adds feed-write so dapps can branch on `"feed-write"` if they
    /// need it, without breaking older clients that only knew
    /// `"publish"`.
    private static let supportedCapabilities = ["publish"]

    private weak var tab: BrowserTab?
    private let router: SwarmRouter
    private let services: SwarmServices
    /// Weak: `WKUserContentController.add(_:name:)` strongly retains us,
    /// so this side of the edge must not retain back — otherwise tab
    /// teardown would never run.
    private weak var contentController: WKUserContentController?

    init(
        tab: BrowserTab,
        router: SwarmRouter,
        contentController: WKUserContentController,
        services: SwarmServices
    ) {
        self.tab = tab
        self.router = router
        self.services = services
        self.contentController = contentController
        super.init()
        contentController.add(self, name: Self.messageHandlerName)
        installUserScript()
    }

    // MARK: - Preload

    private static let preloadSource: String = {
        guard let url = Bundle.main.url(forResource: "SwarmBridge", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("SwarmBridge.js missing from app bundle")
            return ""
        }
        return source
    }()

    /// `WKUserScript` is value-equivalent across navigations (the swarm
    /// preload has no per-navigation parameter), so cache once and re-add
    /// instead of rebuilding per `BrowserTab.reinstallPreloads()`.
    private static let userScript = WKUserScript(
        source: preloadSource,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    func installUserScript() {
        contentController?.addUserScript(Self.userScript)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.messageHandlerName,
              let body = message.body as? [String: Any],
              (body["type"] as? String) == "request",
              let id = body["id"] as? Int,
              let method = body["method"] as? String else { return }
        let params = body["params"] as? [String: Any] ?? [:]
        let origin = OriginIdentity.from(displayURL: tab?.displayURL)

        Task { [weak self] in
            await self?.dispatch(id: id, method: method, params: params, origin: origin)
        }
    }

    private func dispatch(
        id: Int, method: String, params: [String: Any], origin: OriginIdentity?
    ) async {
        guard let origin else {
            return reply(id: id, error: SwarmRouter.ErrorPayload(
                code: SwarmRouter.ErrorPayload.Code.unauthorized,
                message: "No origin identity — cannot route request.",
                dataReason: nil
            ))
        }

        switch method {
        case "swarm_requestAccess":
            await handleRequestAccess(id: id, origin: origin)
            return
        default:
            break
        }

        do {
            let result = try await router.handle(method: method, params: params, origin: origin)
            reply(id: id, result: result)
        } catch {
            reply(id: id, error: router.errorPayload(for: error))
        }
    }

    // MARK: - swarm_requestAccess

    private func handleRequestAccess(id: Int, origin: OriginIdentity) async {
        // Same allowlist as the wallet bridge — see `OriginIdentity`.
        guard origin.isEligibleForWallet else {
            return reply(id: id, error: SwarmRouter.ErrorPayload(
                code: SwarmRouter.ErrorPayload.Code.unauthorized,
                message: "Origin not permitted.",
                dataReason: nil
            ))
        }
        guard tab?.pendingSwarmApproval == nil else {
            return reply(id: id, error: SwarmRouter.ErrorPayload(
                code: SwarmRouter.ErrorPayload.Code.resourceUnavailable,
                message: "Another approval is already pending.",
                dataReason: nil
            ))
        }

        if services.permissionStore.isConnected(origin.key) {
            services.permissionStore.touchLastUsed(origin: origin.key)
            return reply(id: id, result: Self.connectionResult(origin: origin))
        }

        let decision = await parkAndAwait(origin: origin)
        switch decision {
        case .approved:
            services.permissionStore.grant(origin: origin.key)
            emit(event: "connect", data: ["origin": origin.key])
            reply(id: id, result: Self.connectionResult(origin: origin))
        case .denied:
            reply(id: id, error: SwarmRouter.ErrorPayload(
                code: SwarmRouter.ErrorPayload.Code.userRejected,
                message: "User rejected the request.",
                dataReason: nil
            ))
        }
    }

    private func parkAndAwait(origin: OriginIdentity) async -> ApprovalRequest.Decision {
        let decision: ApprovalRequest.Decision = await withCheckedContinuation { cont in
            let request = ApprovalRequest(
                id: UUID(),
                origin: origin,
                kind: .swarmConnect,
                resolver: ApprovalResolver(cont)
            )
            tab?.pendingSwarmApproval = request
        }
        tab?.pendingSwarmApproval = nil
        return decision
    }

    private static func connectionResult(origin: OriginIdentity) -> [String: Any] {
        ["connected": true, "origin": origin.key,
         "capabilities": Self.supportedCapabilities]
    }

    // MARK: - Reply path

    private func reply(id: Int, result: Any) {
        evaluateResponse(id: id, resultJSON: jsonLiteral(result), errorJSON: "null")
    }

    private func reply(id: Int, error: SwarmRouter.ErrorPayload) {
        var dict: [String: Any] = ["code": error.code, "message": error.message]
        if let reason = error.dataReason {
            dict["data"] = ["reason": reason]
        }
        evaluateResponse(id: id, resultJSON: "null", errorJSON: jsonLiteral(dict))
    }

    private func evaluateResponse(id: Int, resultJSON: String, errorJSON: String) {
        guard let webView = tab?.webView else { return }
        let js = "window.__freedomSwarm && window.__freedomSwarm.__handleResponse(\(id), \(resultJSON), \(errorJSON));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func emit(event: String, data: Any) {
        guard let webView = tab?.webView else { return }
        let js = "window.__freedomSwarm && window.__freedomSwarm.__handleEvent(\(jsonLiteral(event)), \(jsonLiteral(data)));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// JSONSerialization quotes + escapes strings, so direct
    /// interpolation into evaluateJavaScript is injection-safe. Returns
    /// `"null"` on failure — the JS handler treats that as a missing
    /// result/error and does nothing.
    private func jsonLiteral(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let string = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return string
    }
}
