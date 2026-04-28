import Foundation
import WebKit

/// Per-`BrowserTab` `window.swarm` bridge. Origin identity is derived
/// from `tab.displayURL` at every message receipt — the JS side never
/// supplies it. Interactive methods that park an `ApprovalRequest`
/// continuation (`swarm_requestAccess`, `swarm_publishData`) live here;
/// everything else routes through `SwarmRouter`.
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
            return replyError(
                id: id,
                code: SwarmRouter.ErrorPayload.Code.unauthorized,
                message: "No origin identity — cannot route request."
            )
        }

        switch method {
        case "swarm_requestAccess":
            await handleRequestAccess(id: id, origin: origin)
            return
        case "swarm_publishData":
            await handlePublishData(id: id, origin: origin, params: params)
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
            return replyError(
                id: id,
                code: SwarmRouter.ErrorPayload.Code.unauthorized,
                message: "Origin not permitted."
            )
        }
        guard tab?.pendingSwarmApproval == nil else {
            return replyError(
                id: id,
                code: SwarmRouter.ErrorPayload.Code.resourceUnavailable,
                message: "Another approval is already pending."
            )
        }

        if services.permissionStore.isConnected(origin.key) {
            services.permissionStore.touchLastUsed(origin: origin.key)
            return reply(id: id, result: Self.connectionResult(origin: origin))
        }

        let decision = await parkAndAwait(origin: origin, kind: .swarmConnect)
        switch decision {
        case .approved:
            services.permissionStore.grant(origin: origin.key)
            emit(event: "connect", data: ["origin": origin.key])
            reply(id: id, result: Self.connectionResult(origin: origin))
        case .denied:
            replyError(
                id: id,
                code: SwarmRouter.ErrorPayload.Code.userRejected,
                message: "User rejected the request."
            )
        }
    }

    private func parkAndAwait(
        origin: OriginIdentity, kind: ApprovalRequest.Kind
    ) async -> ApprovalRequest.Decision {
        let decision: ApprovalRequest.Decision = await withCheckedContinuation { cont in
            let request = ApprovalRequest(
                id: UUID(),
                origin: origin,
                kind: kind,
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

    // MARK: - swarm_publishData

    private struct ParsedPublishData {
        let data: Data
        let contentType: String
        let name: String?
    }

    /// SWIP §"swarm_publishData" — interactive method (parks an
    /// approval), so it sits in the bridge rather than the router.
    /// Order: connection → params → capability gate → stamp pick →
    /// approval (sheet or auto-approve) → upload → reply.
    private func handlePublishData(
        id: Int, origin: OriginIdentity, params: [String: Any]
    ) async {
        let Code = SwarmRouter.ErrorPayload.Code.self
        let Reason = SwarmRouter.ErrorPayload.Reason.self

        guard origin.isEligibleForWallet else {
            return replyError(id: id, code: Code.unauthorized,
                              message: "Origin not permitted.")
        }
        guard services.permissionStore.isConnected(origin.key) else {
            return replyError(
                id: id, code: Code.unauthorized,
                message: "Connect first — \(origin.displayString) isn't authorized.",
                reason: Reason.notConnected
            )
        }
        guard tab?.pendingSwarmApproval == nil else {
            return replyError(id: id, code: Code.resourceUnavailable,
                              message: "Another approval is already pending.")
        }

        let parsed: ParsedPublishData
        do {
            parsed = try Self.parsePublishDataParams(params)
        } catch let SwarmRouter.RouterError.invalidParams(reason, message) {
            return replyError(id: id, code: Code.invalidParams,
                              message: message, reason: reason)
        } catch {
            return replyError(id: id, code: Code.internalError,
                              message: "\(error)")
        }

        // Capability gate. We've already verified `isConnected`, so any
        // reason returned here is node-side (mode/sync/stamps). Routes
        // through the router's same `capabilities` check that backs
        // `swarm_getCapabilities` — keeps the vocabulary aligned.
        let caps = router.capabilities(origin: origin)
        if !caps.canPublish {
            // `capabilities` always sets a reason on `false`; the
            // fallback covers a future invariant break without going
            // silent.
            let reason = caps.reason ?? Reason.nodeNotReady
            return replyError(id: id, code: Code.nodeUnavailable,
                              message: "Node not ready: \(reason)",
                              reason: reason)
        }

        guard let batch = StampService.selectBestBatch(
            forBytes: parsed.data.count,
            in: services.currentStamps()
        ) else {
            return replyError(
                id: id, code: Code.nodeUnavailable,
                message: "No usable stamp with sufficient capacity.",
                reason: Reason.noUsableStamps
            )
        }

        let decision: ApprovalRequest.Decision
        if services.permissionStore.isAutoApprovePublish(origin: origin.key) {
            decision = .approved
        } else {
            decision = await parkAndAwait(
                origin: origin,
                kind: .swarmPublish(SwarmPublishDetails(
                    sizeBytes: parsed.data.count,
                    contentType: parsed.contentType,
                    name: parsed.name
                ))
            )
        }

        switch decision {
        case .denied:
            replyError(id: id, code: Code.userRejected,
                       message: "User rejected the request.")
        case .approved:
            do {
                let result = try await services.publishService.publishData(
                    parsed.data,
                    contentType: parsed.contentType,
                    name: parsed.name,
                    batchID: batch.batchID
                )
                services.permissionStore.touchLastUsed(origin: origin.key)
                reply(id: id, result: [
                    "reference": result.reference,
                    "bzzUrl": "bzz://\(result.reference)",
                ])
            } catch SwarmPublishService.PublishError.unreachable {
                replyError(id: id, code: Code.nodeUnavailable,
                           message: "Bee unreachable.",
                           reason: Reason.nodeStopped)
            } catch {
                replyError(id: id, code: Code.internalError,
                           message: "Publish failed: \(error)")
            }
        }
    }

    /// SWIP §"swarm_publishData" Params: `data` (string in v1; binary
    /// support deferred — `Uint8Array` bridging through WKWebView is
    /// version-dependent and not worth the fragility for the launch
    /// surface), `contentType` (required), `name` (optional). We
    /// enforce `maxDataBytes` from the same `Limits.defaults` the
    /// `swarm_getCapabilities` reply advertises.
    private static func parsePublishDataParams(
        _ params: [String: Any]
    ) throws -> ParsedPublishData {
        guard let str = params["data"] as? String else {
            throw SwarmRouter.RouterError.invalidParams(
                reason: nil,
                message: "data must be a string."
            )
        }

        guard let contentType = params["contentType"] as? String,
              !contentType.isEmpty else {
            throw SwarmRouter.RouterError.invalidParams(
                reason: nil,
                message: "contentType is required."
            )
        }

        // Fail-fast on size before allocating `Data` — `String.utf8.count`
        // is a lazy view, no 10 MB transient buffer for an oversized
        // payload that's about to be rejected anyway.
        let maxBytes = SwarmCapabilities.Limits.defaults.maxDataBytes
        let utf8Count = str.utf8.count
        if utf8Count > maxBytes {
            throw SwarmRouter.RouterError.invalidParams(
                reason: SwarmRouter.ErrorPayload.Reason.payloadTooLarge,
                message: "Payload exceeds \(maxBytes) bytes."
            )
        }
        let payload = Data(str.utf8)

        let nameRaw = params["name"] as? String
        let name = (nameRaw?.isEmpty ?? true) ? nil : nameRaw
        return ParsedPublishData(data: payload, contentType: contentType, name: name)
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

    /// One-line shortcut for `reply(id:error:)` from inside a handler.
    /// Construction-only sugar; the handler still controls when to call.
    private func replyError(
        id: Int, code: Int, message: String, reason: String? = nil
    ) {
        reply(id: id, error: SwarmRouter.ErrorPayload(
            code: code, message: message, dataReason: reason
        ))
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
