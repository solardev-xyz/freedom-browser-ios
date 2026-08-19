import Foundation
import RadicleKit
import WebKit

/// Surface the bridge needs from its hosting tab. `BrowserTab` conforms;
/// tests stub this so the bridge runs without a real WKWebView graph.
@MainActor
protocol RadicleBridgeHost: AnyObject {
    var displayURL: URL? { get }
    var pendingRadicleApproval: ApprovalRequest? { get set }
}

/// Per-`BrowserTab` `window.radicle` bridge — the iOS implementation of
/// the desktop provider (freedom-browser docs/radicle-provider-api.md,
/// draft v0.1). Actions only; repo reads are the `rad:` URL scheme's
/// job and not on iOS yet.
///
/// Origin identity is derived from `tab.displayURL` at every message
/// receipt — the JS side never supplies it. Tier checks re-validate on
/// every call regardless of what the page believes it was granted.
@MainActor
final class RadicleBridge: NSObject, WKScriptMessageHandler {
    static let messageHandlerName = "freedomRadicle"
    private static let specVersion = "0.2"
    private static let writes = ["issue", "issueComment", "issueState", "patchComment"]

    enum ErrorPayload {
        enum Code {
            static let userRejected = 4001
            static let unauthorized = 4100
            static let unsupportedMethod = 4200
            static let unavailable = 4900
            static let invalidParams = -32602
            static let internalError = -32603
        }
        enum Reason {
            static let integrationDisabled = "integration-disabled"
            static let notConnected = "not-connected"
            static let nodeStopped = "node-stopped"
            static let nodeNotReady = "node-not-ready"
            static let invalidRid = "invalid_rid"
            static let invalidId = "invalid_id"
            static let invalidTitle = "invalid_title"
            static let invalidBody = "invalid_body"
            static let invalidLabels = "invalid_labels"
            static let invalidState = "invalid_state"
            static let payloadTooLarge = "payload_too_large"
            static let repoNotFound = "repo_not_found"
            static let announceFailed = "announce_failed"
            static let nativeFailed = "native_failed"
        }
    }

    /// Desktop cob-service LIMITS, byte-for-byte.
    private enum Limits {
        static let maxTitleBytes = 200
        static let maxBodyBytes = 65536
        static let maxLabelBytes = 100
        static let maxLabels = 10
    }

    private weak var host: (any RadicleBridgeHost)?
    private let services: RadicleServices
    /// Weak: WKUserContentController strongly retains us as a handler.
    private weak var contentController: WKUserContentController?
    private let replies: any SwarmBridgeReplies
    private let seedListenerToken = UUID()
    private var revocationObserver: (any NSObjectProtocol)?

    init(
        host: any RadicleBridgeHost,
        services: RadicleServices,
        replies: any SwarmBridgeReplies
    ) {
        self.host = host
        self.services = services
        self.replies = replies
        super.init()
        installEventRelays()
    }

    convenience init(
        tab: BrowserTab,
        contentController: WKUserContentController,
        services: RadicleServices
    ) {
        let replies = BridgeReplyChannel(
            jsGlobal: "__freedomRadicle", webView: tab.webView
        )
        self.init(host: tab, services: services, replies: replies)
        self.contentController = contentController
        contentController.add(self, name: Self.messageHandlerName)
        installUserScript()
    }

    deinit {
        if let revocationObserver {
            NotificationCenter.default.removeObserver(revocationObserver)
        }
    }

    /// `seedStatus` events flow only to origins that used a push method
    /// this session (desktop's broadcaster model); `disconnect` flows to
    /// any tab whose origin just lost its grant — including revocation
    /// from a future chrome-side management UI.
    private func installEventRelays() {
        services.seedTracker.addListener(seedListenerToken) { [weak self] _, payload in
            guard let self, let origin = self.currentOrigin() else { return }
            guard self.services.seedTracker.followingOrigins.contains(origin.key),
                  self.services.permissionStore.isConnected(origin.key) else { return }
            self.replies.emit(event: "seedStatus", data: payload)
        }
        revocationObserver = NotificationCenter.default.addObserver(
            forName: .radiclePermissionRevoked, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let revoked = notification.userInfo?["origin"] as? String,
                      let origin = self.currentOrigin(), origin.key == revoked
                else { return }
                self.replies.emit(event: "disconnect", data: ["origin": revoked])
            }
        }
    }

    /// The tab is being torn down — unhook from the session-scoped
    /// tracker so the relay closure doesn't outlive the page.
    func detach() {
        services.seedTracker.removeListener(seedListenerToken)
    }

    // MARK: - Preload

    private static let preloadSource: String = {
        guard let url = Bundle.main.url(forResource: "RadicleBridge", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("RadicleBridge.js missing from app bundle")
            return ""
        }
        return source
    }()

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
        let origin = currentOrigin()

        Task { [weak self] in
            await self?.dispatch(id: id, method: method, params: params, origin: origin)
        }
    }

    private func currentOrigin() -> OriginIdentity? {
        OriginIdentity.from(displayURL: host?.displayURL)
    }

    // MARK: - Dispatch

    func dispatch(
        id: Int, method: String, params: [String: Any], origin: OriginIdentity?
    ) async {
        guard let origin else {
            return replyError(id: id, code: ErrorPayload.Code.unauthorized,
                              message: "No origin identity — cannot route request.")
        }
        guard services.nodeFailureReason() != ErrorPayload.Reason.integrationDisabled else {
            return replyError(id: id, code: ErrorPayload.Code.unavailable,
                              message: "Radicle integration is disabled",
                              reason: ErrorPayload.Reason.integrationDisabled)
        }

        switch method {
        case "radicle_requestAccess":
            await handleRequestAccess(id: id, origin: origin)
        case "radicle_getCapabilities":
            reply(id: id, result: capabilities(origin: origin))

        // Connection tier -------------------------------------------------
        case "radicle_getNodeStatus":
            guard requireConnected(id: id, origin: origin) else { return }
            await handleGetNodeStatus(id: id, origin: origin)
        case "radicle_listSeededRepos":
            guard requireConnected(id: id, origin: origin),
                  requireNodeRunning(id: id) else { return }
            await handleListSeededRepos(id: id, origin: origin)
        case "radicle_getSeedStatus":
            guard requireConnected(id: id, origin: origin),
                  requireNodeRunning(id: id),
                  let rid = requireRid(id: id, params: params) else { return }
            services.seedTracker.follow(origin: origin.key)
            services.permissionStore.touchLastUsed(origin: origin.key)
            reply(id: id, result: await services.seedTracker.status(rid: rid))
        case "radicle_disconnect":
            guard requireConnected(id: id, origin: origin) else { return }
            services.seedTracker.unfollow(origin: origin.key)
            services.permissionStore.revoke(origin: origin.key)
            reply(id: id, result: ["connected": false])

        // Node tier -------------------------------------------------------
        case "radicle_seed":
            guard requireConnected(id: id, origin: origin),
                  requireNodeRunning(id: id),
                  let rid = requireRid(id: id, params: params) else { return }
            await handleSeed(id: id, origin: origin, rid: rid)
        case "radicle_unseed":
            guard requireConnected(id: id, origin: origin),
                  requireNodeRunning(id: id),
                  let rid = requireRid(id: id, params: params) else { return }
            await handleUnseed(id: id, origin: origin, rid: rid)
        case "radicle_sync":
            guard requireConnected(id: id, origin: origin),
                  requireNodeRunning(id: id),
                  let rid = requireRid(id: id, params: params) else { return }
            services.seedTracker.follow(origin: origin.key)
            services.permissionStore.touchLastUsed(origin: origin.key)
            let status = await services.seedTracker.startFetch(rid: rid)
            reply(id: id, result: ["rid": rid, "status": status])

        // Signing tier ----------------------------------------------------
        case "radicle_getIdentity", "radicle_createIssue", "radicle_commentIssue",
             "radicle_editIssueState", "radicle_commentPatch":
            guard requireConnected(id: id, origin: origin),
                  requireNodeRunning(id: id) else { return }
            guard await requireSigningGrant(id: id, origin: origin) else { return }
            services.permissionStore.touchLastUsed(origin: origin.key)
            await handleSigningMethod(id: id, method: method, params: params)

        default:
            replyError(id: id, code: ErrorPayload.Code.unsupportedMethod,
                       message: "Unknown method: \(method)")
        }
    }

    // MARK: - Capabilities

    private func unavailableReason(origin: OriginIdentity) -> String? {
        if let reason = services.nodeFailureReason() { return reason }
        if !services.permissionStore.isConnected(origin.key) {
            return ErrorPayload.Reason.notConnected
        }
        return nil
    }

    private func capabilities(origin: OriginIdentity) -> [String: Any] {
        let reason = unavailableReason(origin: origin)
        return [
            "specVersion": Self.specVersion,
            "canUseNode": reason == nil,
            "reason": reason as Any? ?? NSNull(),
            "writes": Self.writes,
        ]
    }

    // MARK: - Tier guards

    private func requireConnected(id: Int, origin: OriginIdentity) -> Bool {
        guard services.permissionStore.isConnected(origin.key) else {
            replyError(id: id, code: ErrorPayload.Code.unauthorized,
                       message: "Origin not authorized. Call radicle_requestAccess first.",
                       reason: ErrorPayload.Reason.notConnected)
            return false
        }
        return true
    }

    /// Desktop's WORKS_WHILE_STOPPED set is handled by callers not
    /// invoking this guard (`requestAccess`, `getNodeStatus`,
    /// `disconnect`); everything else needs the running node.
    private func requireNodeRunning(id: Int) -> Bool {
        if let reason = services.nodeFailureReason() {
            replyError(id: id, code: ErrorPayload.Code.unavailable,
                       message: "Radicle node is not running", reason: reason)
            return false
        }
        return true
    }

    private func requireSigningGrant(id: Int, origin: OriginIdentity) async -> Bool {
        if services.permissionStore.hasSigningGrant(origin.key) { return true }
        guard host?.pendingRadicleApproval == nil else {
            replyError(id: id, code: ErrorPayload.Code.unavailable,
                       message: "Another approval is already pending.")
            return false
        }
        // One deliberate grant covers the tier — forge UX, like an OAuth
        // scope, not a per-comment prompt (desktop parity).
        let decision = await parkAndAwait(origin: origin, kind: .radicleSigning)
        guard case .approved = decision else {
            replyError(id: id, code: ErrorPayload.Code.userRejected,
                       message: "User rejected the request.")
            return false
        }
        services.permissionStore.grantSigning(origin: origin.key)
        return true
    }

    private func parkAndAwait(
        origin: OriginIdentity, kind: ApprovalRequest.Kind
    ) async -> ApprovalRequest.Decision {
        let decision: ApprovalRequest.Decision = await withCheckedContinuation { cont in
            let request = ApprovalRequest(
                id: UUID(), origin: origin, kind: kind,
                resolver: ApprovalResolver(cont)
            )
            host?.pendingRadicleApproval = request
        }
        host?.pendingRadicleApproval = nil
        return decision
    }

    // MARK: - radicle_requestAccess

    private func handleRequestAccess(id: Int, origin: OriginIdentity) async {
        guard origin.isEligibleForWallet else {
            return replyError(id: id, code: ErrorPayload.Code.unauthorized,
                              message: "Origin not permitted.")
        }
        if !services.permissionStore.isConnected(origin.key) {
            guard host?.pendingRadicleApproval == nil else {
                return replyError(id: id, code: ErrorPayload.Code.unavailable,
                                  message: "Another approval is already pending.")
            }
            let decision = await parkAndAwait(origin: origin, kind: .radicleConnect)
            guard case .approved = decision else {
                return replyError(id: id, code: ErrorPayload.Code.userRejected,
                                  message: "User rejected the request.")
            }
            services.permissionStore.grant(origin: origin.key)
            emit(event: "connect", data: ["origin": origin.key])
        } else {
            services.permissionStore.touchLastUsed(origin: origin.key)
        }
        reply(id: id, result: [
            "connected": true,
            "origin": origin.key,
            "capabilities": capabilities(origin: origin),
        ])
    }

    // MARK: - Connection-tier handlers

    private func handleGetNodeStatus(id: Int, origin: OriginIdentity) async {
        services.permissionStore.touchLastUsed(origin: origin.key)
        let running = services.nodeFailureReason() == nil
        var result: [String: Any] = [
            "running": running,
            "status": services.node.status.rawValue,
        ]
        if running {
            let status = decode(await services.node.statusJSON())
            if let peers = status["connectedPeers"] as? Int { result["peers"] = peers }
            let identity = decode(await services.node.identityJSON())
            // Alias is public data (gossiped network-wide); the NID stays
            // behind the signing grant — it pins a node identity.
            if let alias = identity["alias"] as? String { result["alias"] = alias }
            if services.permissionStore.hasSigningGrant(origin.key),
               let nid = identity["nid"] as? String {
                result["nid"] = nid
            }
        }
        reply(id: id, result: result)
    }

    private func handleListSeededRepos(id: Int, origin: OriginIdentity) async {
        services.permissionStore.touchLastUsed(origin: origin.key)
        let json = await services.node.listSeededReposJSON()
        if let repos = (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
            as? [[String: Any]] {
            reply(id: id, result: repos)
        } else {
            replyNativeError(id: id, json: json, fallback: "repo listing failed")
        }
    }

    // MARK: - Node-tier handlers

    private func handleSeed(id: Int, origin: OriginIdentity, rid: String) async {
        if !services.permissionStore.isAutoApproveSeed(origin: origin.key) {
            guard host?.pendingRadicleApproval == nil else {
                return replyError(id: id, code: ErrorPayload.Code.unavailable,
                                  message: "Another approval is already pending.")
            }
            let decision = await parkAndAwait(origin: origin, kind: .radicleSeed(rid: rid))
            guard case .approved = decision else {
                return replyError(id: id, code: ErrorPayload.Code.userRejected,
                                  message: "User rejected the request.")
            }
        }
        services.seedTracker.follow(origin: origin.key)
        services.permissionStore.touchLastUsed(origin: origin.key)
        let status = await services.seedTracker.startFetch(rid: rid)
        reply(id: id, result: ["rid": rid, "seeded": true, "status": status])
    }

    private func handleUnseed(id: Int, origin: OriginIdentity, rid: String) async {
        services.permissionStore.touchLastUsed(origin: origin.key)
        await services.seedTracker.cancelFetch(rid: rid)
        let json = await services.node.unseedRepoJSON(rid: rid)
        let decoded = decode(json)
        if decoded["error"] == nil {
            reply(id: id, result: ["rid": rid, "seeded": false])
        } else {
            replyNativeError(id: id, json: json, fallback: "unseed failed")
        }
    }

    // MARK: - Signing-tier handlers

    private func handleSigningMethod(
        id: Int, method: String, params: [String: Any]
    ) async {
        switch method {
        case "radicle_getIdentity":
            let json = await services.node.identityJSON()
            let decoded = decode(json)
            if decoded["error"] == nil {
                reply(id: id, result: decoded)
            } else {
                replyNativeError(id: id, json: json, fallback: "identity unavailable")
            }

        case "radicle_createIssue":
            guard let rid = requireRid(id: id, params: params),
                  let title = requireText(id: id, params: params, field: "title",
                                          reason: ErrorPayload.Reason.invalidTitle,
                                          maxBytes: Limits.maxTitleBytes),
                  let description = requireText(id: id, params: params, field: "description",
                                                reason: ErrorPayload.Reason.invalidBody,
                                                maxBytes: Limits.maxBodyBytes),
                  let labels = requireLabels(id: id, params: params) else { return }
            let json = await services.node.createIssueJSON(
                rid: rid, title: title, description: description, labels: labels
            )
            replyCobResult(id: id, json: json)

        case "radicle_commentIssue":
            guard let rid = requireRid(id: id, params: params),
                  let issueId = requireCobId(id: id, params: params, field: "issueId"),
                  let body = requireText(id: id, params: params, field: "body",
                                         reason: ErrorPayload.Reason.invalidBody,
                                         maxBytes: Limits.maxBodyBytes) else { return }
            var replyTo: String?
            if params["replyTo"] != nil, !(params["replyTo"] is NSNull) {
                guard let validated = requireCobId(id: id, params: params, field: "replyTo")
                else { return }
                replyTo = validated
            }
            let json = await services.node.commentIssueJSON(
                rid: rid, issueId: issueId, body: body, replyTo: replyTo
            )
            replyCobResult(id: id, json: json)

        case "radicle_editIssueState":
            guard let rid = requireRid(id: id, params: params),
                  let issueId = requireCobId(id: id, params: params, field: "issueId")
            else { return }
            guard let state = params["state"] as? String,
                  ["open", "closed", "solved"].contains(state) else {
                return replyError(id: id, code: ErrorPayload.Code.invalidParams,
                                  message: "state must be 'open', 'closed' or 'solved'",
                                  reason: ErrorPayload.Reason.invalidState)
            }
            let json = await services.node.editIssueStateJSON(
                rid: rid, issueId: issueId, state: state
            )
            replyCobResult(id: id, json: json)

        case "radicle_commentPatch":
            guard let rid = requireRid(id: id, params: params),
                  let patchId = requireCobId(id: id, params: params, field: "patchId"),
                  let body = requireText(id: id, params: params, field: "body",
                                         reason: ErrorPayload.Reason.invalidBody,
                                         maxBytes: Limits.maxBodyBytes) else { return }
            // The patch id doubles as the first revision's id, so callers
            // without a specific revision pass the patch id (desktop parity).
            var revisionId = patchId
            if params["revisionId"] != nil, !(params["revisionId"] is NSNull) {
                guard let validated = requireCobId(id: id, params: params, field: "revisionId")
                else { return }
                revisionId = validated
            }
            let json = await services.node.commentPatchJSON(
                rid: rid, revisionId: revisionId, body: body
            )
            replyCobResult(id: id, json: json)

        default:
            replyError(id: id, code: ErrorPayload.Code.unsupportedMethod,
                       message: "Unknown method: \(method)")
        }
    }

    // MARK: - Validation (desktop cob-service parity)

    /// `z` + base58, 20–60 chars, with optional `rad:` / `rad://`
    /// prefix; normalized to the canonical `rad:z…` form the Rust layer
    /// parses.
    static func validateAndNormalizeRid(_ raw: Any?) -> String? {
        guard var bare = raw as? String else { return nil }
        if bare.hasPrefix("rad://") { bare = String(bare.dropFirst(6)) }
        else if bare.hasPrefix("rad:") { bare = String(bare.dropFirst(4)) }
        guard bare.range(
            of: "^z[1-9A-HJ-NP-Za-km-z]{20,60}$", options: .regularExpression
        ) != nil else { return nil }
        return "rad:\(bare)"
    }

    private func requireRid(id: Int, params: [String: Any]) -> String? {
        guard let rid = Self.validateAndNormalizeRid(params["rid"]) else {
            replyError(id: id, code: ErrorPayload.Code.invalidParams,
                       message: "Invalid Radicle repository ID",
                       reason: ErrorPayload.Reason.invalidRid)
            return nil
        }
        return rid
    }

    /// COB ids as accepted by the CLI: full or truncated hex.
    private func requireCobId(id: Int, params: [String: Any], field: String) -> String? {
        guard let value = params[field] as? String,
              value.range(of: "^[0-9a-f]{6,40}$", options: .regularExpression) != nil
        else {
            replyError(id: id, code: ErrorPayload.Code.invalidParams,
                       message: "Invalid collaborative object id",
                       reason: ErrorPayload.Reason.invalidId)
            return nil
        }
        return value
    }

    private func requireText(
        id: Int, params: [String: Any], field: String, reason: String, maxBytes: Int
    ) -> String? {
        guard let value = params[field] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            replyError(id: id, code: ErrorPayload.Code.invalidParams,
                       message: "\(field) must be a non-empty string", reason: reason)
            return nil
        }
        guard value.utf8.count <= maxBytes else {
            replyError(id: id, code: ErrorPayload.Code.invalidParams,
                       message: "\(field) exceeds \(maxBytes) bytes",
                       reason: ErrorPayload.Reason.payloadTooLarge)
            return nil
        }
        return value
    }

    private func requireLabels(id: Int, params: [String: Any]) -> [String]? {
        guard params["labels"] != nil, !(params["labels"] is NSNull) else { return [] }
        guard let labels = params["labels"] as? [String],
              labels.count <= Limits.maxLabels,
              labels.allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.utf8.count <= Limits.maxLabelBytes
              }) else {
            replyError(id: id, code: ErrorPayload.Code.invalidParams,
                       message: "labels must be an array of short strings (max \(Limits.maxLabels))",
                       reason: ErrorPayload.Reason.invalidLabels)
            return nil
        }
        return labels
    }

    // MARK: - Replies

    private func decode(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    /// COB writes reply `{id, ...}` on success or a mapped native error.
    private func replyCobResult(id: Int, json: String) {
        let decoded = decode(json)
        if decoded["error"] == nil, decoded["id"] != nil {
            reply(id: id, result: decoded)
        } else {
            replyNativeError(id: id, json: json, fallback: "write failed")
        }
    }

    /// Desktop's nativeError mapping: announce / not-found regexes over
    /// the addon's message become machine-readable reasons.
    private func replyNativeError(id: Int, json: String, fallback: String) {
        let message = decode(json)["error"] as? String ?? fallback
        let lowered = message.lowercased()
        let reason: String
        if lowered.contains("announce refs failed") {
            reason = ErrorPayload.Reason.announceFailed
        } else if lowered.contains("not found") {
            reason = ErrorPayload.Reason.repoNotFound
        } else {
            reason = ErrorPayload.Reason.nativeFailed
        }
        replyError(id: id, code: ErrorPayload.Code.internalError,
                   message: message, reason: reason)
    }

    private func reply(id: Int, result: Any) {
        replies.reply(id: id, result: result)
    }

    private func replyError(id: Int, code: Int, message: String, reason: String? = nil) {
        var error: [String: Any] = ["code": code, "message": message]
        if let reason { error["data"] = ["reason": reason] }
        replies.reply(id: id, errorObject: error)
    }

    private func emit(event: String, data: Any) {
        replies.emit(event: event, data: data)
    }
}

extension BrowserTab: RadicleBridgeHost {}
