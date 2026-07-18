import Foundation
import web3
import WebKit

/// Surface the bridge needs from its hosting tab. `BrowserTab` conforms;
/// tests stub this so the bridge can be exercised without a real
/// `WKWebView` / `BrowserTab` graph.
@MainActor
protocol SwarmBridgeHost: AnyObject {
    var displayURL: URL? { get }
    var pendingSwarmApproval: ApprovalRequest? { get set }
}

/// Reply transport. `BridgeReplyChannel` conforms (production); tests
/// inject a recording stub.
@MainActor
protocol SwarmBridgeReplies {
    func reply(id: Int, result: Any)
    func reply(id: Int, errorObject: [String: Any])
    func emit(event: String, data: Any)
}

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
    /// SWIP §"swarm_getUploadStatus": "Tag not found or not owned by
    /// this origin." Used both when the tag was never recorded under
    /// this origin and when bee evicted it; same desktop wording.
    private static let tagNotOwnedMessage = "Tag not found or not owned by this origin."

    private weak var host: (any SwarmBridgeHost)?
    private let router: SwarmRouter
    private let services: SwarmServices
    /// Weak: `WKUserContentController.add(_:name:)` strongly retains us,
    /// so this side of the edge must not retain back — otherwise tab
    /// teardown would never run.
    private weak var contentController: WKUserContentController?
    private let replies: any SwarmBridgeReplies

    /// Test-friendly designated init. No WebKit side effects; production
    /// uses the convenience init below which adds message-handler
    /// registration + JS preload install.
    init(
        host: any SwarmBridgeHost,
        router: SwarmRouter,
        services: SwarmServices,
        replies: any SwarmBridgeReplies
    ) {
        self.host = host
        self.router = router
        self.services = services
        self.replies = replies
        super.init()
    }

    convenience init(
        tab: BrowserTab,
        router: SwarmRouter,
        contentController: WKUserContentController,
        services: SwarmServices
    ) {
        let replies = BridgeReplyChannel(
            jsGlobal: "__freedomSwarm", webView: tab.webView
        )
        self.init(host: tab, router: router, services: services, replies: replies)
        self.contentController = contentController
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
        let origin = OriginIdentity.from(displayURL: host?.displayURL)

        Task { [weak self] in
            await self?.dispatch(id: id, method: method, params: params, origin: origin)
        }
    }

    func dispatch(
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
        case "swarm_publishFiles":
            await handlePublishFiles(id: id, origin: origin, params: params)
            return
        case "swarm_getUploadStatus":
            await handleGetUploadStatus(id: id, origin: origin, params: params)
            return
        case "swarm_createFeed":
            await handleCreateFeed(id: id, origin: origin, params: params)
            return
        case "swarm_updateFeed":
            await handleUpdateFeed(id: id, origin: origin, params: params)
            return
        case "swarm_writeFeedEntry":
            await handleWriteFeedEntry(id: id, origin: origin, params: params)
            return
        case "swarm_publishChunk":
            await handlePublishChunk(id: id, origin: origin, params: params)
            return
        case "swarm_writeSingleOwnerChunk":
            await handleWriteSingleOwnerChunk(id: id, origin: origin, params: params)
            return
        case "swarm_getSigningIdentity":
            await handleGetSigningIdentity(id: id, origin: origin)
            return
        case "swarm_getMessagingIdentity":
            await handleGetMessagingIdentity(id: id, origin: origin)
            return
        case "swarm_subscribe":
            await handleSubscribe(id: id, origin: origin, params: params)
            return
        case "swarm_unsubscribe":
            await handleUnsubscribe(id: id, origin: origin, params: params)
            return
        case "swarm_sendPss":
            await handleSendPss(id: id, origin: origin, params: params)
            return
        case "swarm_sendGsoc":
            await handleSendGsoc(id: id, origin: origin, params: params)
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

    // MARK: - Approval-flow guards

    /// `true` iff the origin is on the wallet allowlist and no other
    /// swarm approval is currently parked. Mirrors
    /// `EthereumBridge.assertEligibleAndFree` (different pending slot).
    /// Replies with the appropriate error and returns `false` otherwise.
    private func assertEligibleAndFree(id: Int, origin: OriginIdentity) -> Bool {
        let Code = SwarmRouter.ErrorPayload.Code.self
        guard origin.isEligibleForWallet else {
            replyError(id: id, code: Code.unauthorized,
                       message: "Origin not permitted.")
            return false
        }
        guard host?.pendingSwarmApproval == nil else {
            replyError(id: id, code: Code.resourceUnavailable,
                       message: "Another approval is already pending.")
            return false
        }
        return true
    }

    /// Bookkeeping after a `publishData` / `publishFiles` upload
    /// returns successfully — touch `lastUsedAt` and (when bee returned
    /// a tag) record `(tagUid, origin)` for the cross-origin defense in
    /// `swarm_getUploadStatus`. With WP5.3's `Swarm-Deferred-Upload:
    /// true` the tag is reliably present, but the optional check
    /// stays for robustness.
    private func recordPublishSuccess(tagUid: Int?, origin: OriginIdentity) {
        services.permissionStore.touchLastUsed(origin: origin.key)
        if let tagUid {
            services.tagOwnership.record(tag: tagUid, origin: origin.key)
        }
    }

    /// `true` iff the origin has previously been granted a swarm
    /// connection via `swarm_requestAccess`. Replies with `4100
    /// not-connected` and returns `false` otherwise.
    private func requireConnectedOrigin(id: Int, origin: OriginIdentity) -> Bool {
        guard services.permissionStore.isConnected(origin.key) else {
            replyError(
                id: id,
                code: SwarmRouter.ErrorPayload.Code.unauthorized,
                message: "Connect first — \(origin.displayString) isn't authorized.",
                reason: SwarmRouter.ErrorPayload.Reason.notConnected
            )
            return false
        }
        return true
    }

    /// True when feed auto-approve grant exists *and* the vault is
    /// unlocked. The auto-approve toggle skips the sheet, but the
    /// sheet bakes in `ApprovalUnlockStrip` — silently firing
    /// `signingKey(...)` on a locked vault would 4900 with `notUnlocked`
    /// instead of giving the user a chance to unlock. So a locked
    /// vault has to fall through to the sheet regardless.
    private func feedAutoApproveActive(origin: OriginIdentity) -> Bool {
        services.permissionStore.isAutoApproveFeeds(origin: origin.key)
            && services.vault.state == .unlocked
    }

    /// Routes through the router's `capabilities` (same vocabulary as
    /// `swarm_getCapabilities`) so dapps see the same `reason` strings
    /// across the feature-detect read and the write-time error. Replies
    /// `4900 nodeUnavailable` and returns `false` if not ready.
    private func requireCanPublish(id: Int, origin: OriginIdentity) -> Bool {
        let caps = router.capabilities(origin: origin)
        guard caps.canPublish else {
            // `capabilities` always sets a reason on `false`; fallback
            // covers a future invariant break without going silent.
            let reason = caps.reason ?? SwarmRouter.ErrorPayload.Reason.nodeNotReady
            replyError(id: id,
                       code: SwarmRouter.ErrorPayload.Code.nodeUnavailable,
                       message: "Node not ready: \(reason)",
                       reason: reason)
            return false
        }
        return true
    }

    // MARK: - swarm_requestAccess

    private func handleRequestAccess(id: Int, origin: OriginIdentity) async {
        guard assertEligibleAndFree(id: id, origin: origin) else { return }

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
            host?.pendingSwarmApproval = request
        }
        host?.pendingSwarmApproval = nil
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

        guard assertEligibleAndFree(id: id, origin: origin),
              requireConnectedOrigin(id: id, origin: origin) else { return }

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

        guard requireCanPublish(id: id, origin: origin) else { return }

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
                    mode: .data(contentType: parsed.contentType, name: parsed.name)
                ))
            )
        }

        switch decision {
        case .denied:
            replyError(id: id, code: Code.userRejected,
                       message: "User rejected the request.")
        case .approved:
            let historyRow = services.publishHistoryStore.record(
                kind: .data, name: parsed.name, origin: origin.key,
                bytesSize: parsed.data.count
            )
            do {
                let result = try await services.publishService.publishData(
                    parsed.data,
                    contentType: parsed.contentType,
                    name: parsed.name,
                    batchID: batch.batchID
                )
                recordPublishSuccess(tagUid: result.tagUid, origin: origin)
                services.publishHistoryStore.complete(
                    historyRow, reference: result.reference,
                    tagUid: result.tagUid, batchId: batch.batchID
                )
                reply(id: id, result: [
                    "reference": result.reference,
                    "bzzUrl": "bzz://\(result.reference)",
                ])
            } catch SwarmPublishService.PublishError.unreachable {
                services.publishHistoryStore.fail(historyRow, errorMessage: "Bee unreachable.")
                replyError(id: id, code: Code.nodeUnavailable,
                           message: "Bee unreachable.",
                           reason: Reason.nodeStopped)
            } catch {
                services.publishHistoryStore.fail(historyRow, errorMessage: "Publish failed: \(error)")
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

    // MARK: - swarm_publishFiles

    private struct ParsedPublishFiles {
        let entries: [TarBuilder.Entry]
        let totalBytes: Int
        let indexDocument: String?
    }

    /// Same shape as `handlePublishData` — same eligibility / connection
    /// / capability gates, same approval flow, same upload path. The
    /// only differences are param shape (files array, not a single
    /// payload) and that the body sent to bee is a USTAR tar built by
    /// `TarBuilder` rather than the raw bytes.
    private func handlePublishFiles(
        id: Int, origin: OriginIdentity, params: [String: Any]
    ) async {
        let Code = SwarmRouter.ErrorPayload.Code.self
        let Reason = SwarmRouter.ErrorPayload.Reason.self

        guard assertEligibleAndFree(id: id, origin: origin),
              requireConnectedOrigin(id: id, origin: origin) else { return }

        let parsed: ParsedPublishFiles
        do {
            parsed = try Self.parsePublishFilesParams(params)
        } catch let SwarmRouter.RouterError.invalidParams(reason, message) {
            return replyError(id: id, code: Code.invalidParams,
                              message: message, reason: reason)
        } catch {
            return replyError(id: id, code: Code.internalError,
                              message: "\(error)")
        }

        guard requireCanPublish(id: id, origin: origin) else { return }

        guard let batch = StampService.selectBestBatch(
            forBytes: parsed.totalBytes,
            in: services.currentStamps()
        ) else {
            return replyError(
                id: id, code: Code.nodeUnavailable,
                message: "No usable stamp with sufficient capacity.",
                reason: Reason.noUsableStamps
            )
        }

        let tarBytes: Data
        do {
            tarBytes = try TarBuilder.build(entries: parsed.entries)
        } catch TarBuilder.Error.pathTooLong(let path) {
            return replyError(
                id: id, code: Code.invalidParams,
                message: "path exceeds 100-char USTAR limit: \(path)"
            )
        } catch {
            return replyError(id: id, code: Code.internalError,
                              message: "tar build failed: \(error)")
        }

        let decision: ApprovalRequest.Decision
        if services.permissionStore.isAutoApprovePublish(origin: origin.key) {
            decision = .approved
        } else {
            decision = await parkAndAwait(
                origin: origin,
                kind: .swarmPublish(SwarmPublishDetails(
                    sizeBytes: parsed.totalBytes,
                    mode: .files(
                        paths: parsed.entries.map(\.path),
                        indexDocument: parsed.indexDocument
                    )
                ))
            )
        }

        switch decision {
        case .denied:
            replyError(id: id, code: Code.userRejected,
                       message: "User rejected the request.")
        case .approved:
            // `indexDocument` reads best as the row label; first path is
            // a usable fallback for tree uploads that don't designate
            // one. UI never has to render an unnamed row.
            let historyName = parsed.indexDocument ?? parsed.entries.first?.path
            let historyRow = services.publishHistoryStore.record(
                kind: .files, name: historyName, origin: origin.key,
                bytesSize: parsed.totalBytes
            )
            do {
                let result = try await services.publishService.publishFiles(
                    tarBytes,
                    indexDocument: parsed.indexDocument,
                    batchID: batch.batchID
                )
                recordPublishSuccess(tagUid: result.tagUid, origin: origin)
                services.publishHistoryStore.complete(
                    historyRow, reference: result.reference,
                    tagUid: result.tagUid, batchId: batch.batchID
                )
                reply(id: id, result: [
                    "reference": result.reference,
                    "bzzUrl": "bzz://\(result.reference)",
                    "tagUid": result.tagUid as Any? ?? NSNull(),
                ])
            } catch SwarmPublishService.PublishError.unreachable {
                services.publishHistoryStore.fail(historyRow, errorMessage: "Bee unreachable.")
                replyError(id: id, code: Code.nodeUnavailable,
                           message: "Bee unreachable.",
                           reason: Reason.nodeStopped)
            } catch {
                services.publishHistoryStore.fail(historyRow, errorMessage: "Publish failed: \(error)")
                replyError(id: id, code: Code.internalError,
                           message: "Publish failed: \(error)")
            }
        }
    }

    /// SWIP §"swarm_publishFiles" Params: `files: [{path, bytes,
    /// contentType?}]`, optional `indexDocument`. Per-file `bytes` is
    /// always a base64 string here — the JS preload's `__toBase64`
    /// wrapper normalizes `Uint8Array`/`ArrayBuffer` before postMessage
    /// so the native side has a consistent shape regardless of the
    /// dapp's input form. `contentType` is accepted but ignored at
    /// upload time (bee-js's `uploadFilesFromDirectory` infers MIME
    /// from extensions; we follow that — desktop has the same
    /// limitation).
    private static func parsePublishFilesParams(
        _ params: [String: Any]
    ) throws -> ParsedPublishFiles {
        guard let filesRaw = params["files"] as? [[String: Any]],
              !filesRaw.isEmpty else {
            throw SwarmRouter.RouterError.invalidParams(
                reason: nil,
                message: "files must be a non-empty array."
            )
        }
        let limits = SwarmCapabilities.Limits.defaults
        if filesRaw.count > limits.maxFileCount {
            throw SwarmRouter.RouterError.invalidParams(
                reason: SwarmRouter.ErrorPayload.Reason.payloadTooLarge,
                message: "file count exceeds \(limits.maxFileCount)."
            )
        }
        var seenPaths = Set<String>()
        var entries: [TarBuilder.Entry] = []
        var totalBytes = 0
        for (i, fileRaw) in filesRaw.enumerated() {
            guard let path = fileRaw["path"] as? String else {
                throw SwarmRouter.RouterError.invalidParams(
                    reason: nil,
                    message: "files[\(i)].path must be a string."
                )
            }
            try validateVirtualPath(path, index: i)
            guard seenPaths.insert(path).inserted else {
                throw SwarmRouter.RouterError.invalidParams(
                    reason: nil,
                    message: "Duplicate path: \(path)"
                )
            }
            guard let base64 = fileRaw["bytes"] as? String,
                  let bytes = Data(base64Encoded: base64) else {
                throw SwarmRouter.RouterError.invalidParams(
                    reason: nil,
                    message: "files[\(i)].bytes must be a base64-encoded string."
                )
            }
            totalBytes += bytes.count
            entries.append(TarBuilder.Entry(path: path, bytes: bytes))
        }
        if totalBytes > limits.maxFilesBytes {
            throw SwarmRouter.RouterError.invalidParams(
                reason: SwarmRouter.ErrorPayload.Reason.payloadTooLarge,
                message: "Total size exceeds \(limits.maxFilesBytes) bytes."
            )
        }
        let indexDocument = (params["indexDocument"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        }
        if let indexDocument, !seenPaths.contains(indexDocument) {
            throw SwarmRouter.RouterError.invalidParams(
                reason: nil,
                message: "indexDocument must match an existing file path."
            )
        }
        return ParsedPublishFiles(
            entries: entries, totalBytes: totalBytes, indexDocument: indexDocument
        )
    }

    /// SWIP §"Path validation rules" — applies before tar-build so the
    /// bridge can return `-32602` with a clear message instead of bee
    /// rejecting the upload mid-stream. The byte cap reads from
    /// `Limits.defaults.maxPathBytes` so the `swarm_getCapabilities`
    /// reply and the validator stay in lockstep.
    private static func validateVirtualPath(_ path: String, index: Int) throws {
        if path.isEmpty {
            throw SwarmRouter.RouterError.invalidParams(
                reason: nil, message: "files[\(index)].path is empty."
            )
        }
        // The cap is a *byte* limit on the USTAR header field; multi-
        // byte UTF-8 chars count toward it. `String.count` (Characters)
        // would miss the difference and let through paths that silently
        // truncate inside `TarBuilder.header`.
        let maxPathBytes = SwarmCapabilities.Limits.defaults.maxPathBytes
        if path.utf8.count > maxPathBytes {
            throw SwarmRouter.RouterError.invalidParams(
                reason: nil,
                message: "files[\(index)].path exceeds \(maxPathBytes)-byte limit."
            )
        }
        if path.contains("\\") {
            throw SwarmRouter.RouterError.invalidParams(
                reason: nil,
                message: "files[\(index)].path: backslashes not allowed."
            )
        }
        if path.hasPrefix("/") {
            throw SwarmRouter.RouterError.invalidParams(
                reason: nil,
                message: "files[\(index)].path: leading slash not allowed."
            )
        }
        for scalar in path.unicodeScalars where scalar.value < 32 {
            throw SwarmRouter.RouterError.invalidParams(
                reason: nil,
                message: "files[\(index)].path: control chars not allowed."
            )
        }
        for segment in path.split(separator: "/", omittingEmptySubsequences: false) {
            if segment.isEmpty {
                throw SwarmRouter.RouterError.invalidParams(
                    reason: nil,
                    message: "files[\(index)].path: empty segment."
                )
            }
            if segment == "." || segment == ".." {
                throw SwarmRouter.RouterError.invalidParams(
                    reason: nil,
                    message: "files[\(index)].path: '.' / '..' not allowed."
                )
            }
        }
    }

    // MARK: - swarm_getUploadStatus

    /// SWIP §"swarm_getUploadStatus". Non-interactive (no approval),
    /// but lives in the bridge anyway so the cross-origin scoping
    /// check can read `tab`/`origin` and `services.tagOwnership`. The
    /// SWIP requires `4100` for "tag not owned"; we conflate that
    /// with "we forgot the tag" and "bee evicted the tag" into a
    /// single error to match desktop's behavior.
    private func handleGetUploadStatus(
        id: Int, origin: OriginIdentity, params: [String: Any]
    ) async {
        let Code = SwarmRouter.ErrorPayload.Code.self

        guard origin.isEligibleForWallet else {
            return replyError(id: id, code: Code.unauthorized,
                              message: "Origin not permitted.")
        }

        guard let tagUid = BeeAPIClient.intFromAnyJSON(params["tagUid"]),
              tagUid > 0 else {
            return replyError(id: id, code: Code.invalidParams,
                              message: "tagUid must be a positive integer.")
        }

        guard services.tagOwnership.owner(of: tagUid) == origin.key else {
            return replyError(id: id, code: Code.unauthorized,
                              message: Self.tagNotOwnedMessage)
        }

        let tag: BeeAPIClient.TagResponse
        do {
            tag = try await services.getTag(tagUid)
        } catch BeeAPIClient.Error.notFound {
            // Bee evicted the tag — drop our record so the next call
            // takes the unauthorized path on the in-memory check
            // alone (saves the round-trip).
            services.tagOwnership.forget(tag: tagUid)
            return replyError(id: id, code: Code.unauthorized,
                              message: Self.tagNotOwnedMessage)
        } catch BeeAPIClient.Error.notRunning {
            return replyError(
                id: id, code: Code.nodeUnavailable,
                message: "Bee unreachable.",
                reason: SwarmRouter.ErrorPayload.Reason.nodeStopped
            )
        } catch {
            return replyError(id: id, code: Code.internalError,
                              message: "\(error)")
        }

        if tag.isDone {
            services.tagOwnership.forget(tag: tagUid)
        }
        reply(id: id, result: [
            "tagUid": tag.uid,
            "split": tag.split,
            "seen": tag.seen,
            "stored": tag.stored,
            "sent": tag.sent,
            "synced": tag.synced,
            "progress": tag.progressPercent,
            "done": tag.isDone,
        ])
    }

    // MARK: - swarm_createFeed

    /// SWIP §"swarm_createFeed". On a first grant the sheet writes the
    /// `SwarmFeedIdentity` row before resuming, so the bridge can read
    /// the chosen mode + allocated publisher index back without parking
    /// any extra state.
    private func handleCreateFeed(
        id: Int, origin: OriginIdentity, params: [String: Any]
    ) async {
        let Code = SwarmRouter.ErrorPayload.Code.self
        let Reason = SwarmRouter.ErrorPayload.Reason.self

        guard assertEligibleAndFree(id: id, origin: origin),
              requireConnectedOrigin(id: id, origin: origin) else { return }

        guard let name = params["name"] as? String,
              SwarmRouter.isValidFeedName(name) else {
            return replyError(id: id, code: Code.invalidParams,
                              message: "name must be 1-64 chars, no '/', no control chars.",
                              reason: Reason.invalidFeedName)
        }

        // SWIP-required idempotency. By invariant a feed record can
        // only exist if the identity was set during the original
        // create — a missing identity here is a true invariant break,
        // surface it loudly rather than papering over with a default.
        if let existing = services.feedStore.lookup(origin: origin.key, name: name) {
            guard let identity = services.feedStore.feedIdentity(origin: origin.key) else {
                return replyError(id: id, code: Code.internalError,
                                  message: "Feed record without matching identity.")
            }
            services.permissionStore.touchLastUsed(origin: origin.key)
            return reply(id: id, result: Self.createFeedResult(
                feedId: existing.name, owner: existing.owner,
                topic: existing.topic, manifestRef: existing.manifestReference,
                identityMode: identity.identityMode.rawValue
            ))
        }

        guard requireCanPublish(id: id, origin: origin) else { return }

        // First grant always shows the sheet so the user can pick the
        // identity mode; auto-approve only kicks in for subsequent
        // grants once the mode is locked.
        let isFirstGrant = services.feedStore.feedIdentity(origin: origin.key) == nil
        let decision: ApprovalRequest.Decision
        if !isFirstGrant && feedAutoApproveActive(origin: origin) {
            decision = .approved
        } else {
            decision = await parkAndAwait(
                origin: origin,
                kind: .swarmFeedAccess(SwarmFeedAccessDetails(
                    scope: .feed(name: name), isFirstGrant: isFirstGrant
                ))
            )
        }
        guard case .approved = decision else {
            return replyError(id: id, code: Code.userRejected,
                              message: "User rejected the request.")
        }

        // The sheet's approve() writes SwarmFeedIdentity before
        // resolving — a missing row here means a future code path
        // bypassed that contract; surface loudly.
        guard let identity = services.feedStore.feedIdentity(origin: origin.key) else {
            return replyError(id: id, code: Code.internalError,
                              message: "Feed identity missing after approval.")
        }

        let ownerHex: String
        do {
            let privateKey = try identity.signingKey(via: services.vault)
            ownerHex = try FeedSigner.ownerAddressBytes(privateKey: privateKey)
                .web3.hexString.web3.noHexPrefix
        } catch {
            return replyError(id: id, code: Code.internalError,
                              message: "Couldn't derive feed signing key: \(error)")
        }

        let topicHex = FeedTopic.derive(origin: origin.key, name: name)

        guard let batch = StampService.selectBestBatch(
            forBytes: StampService.estimatedBytes(forFeedWrite: 0),
            in: services.currentStamps()
        ) else {
            return replyError(id: id, code: Code.nodeUnavailable,
                              message: "No usable stamp.",
                              reason: Reason.noUsableStamps)
        }

        let historyRow = services.publishHistoryStore.record(
            kind: .feedCreate, name: name, origin: origin.key
        )
        do {
            let result = try await services.feedService.createFeed(
                ownerHex: ownerHex, topicHex: topicHex, batchID: batch.batchID
            )
            services.feedStore.upsert(
                origin: origin.key, name: name,
                topic: topicHex, owner: ownerHex,
                manifestReference: result.manifestReference
            )
            services.permissionStore.touchLastUsed(origin: origin.key)
            services.publishHistoryStore.complete(
                historyRow, reference: result.manifestReference,
                batchId: batch.batchID
            )
            reply(id: id, result: Self.createFeedResult(
                feedId: name, owner: ownerHex, topic: topicHex,
                manifestRef: result.manifestReference,
                identityMode: identity.identityMode.rawValue
            ))
        } catch SwarmFeedService.FeedServiceError.unreachable {
            services.publishHistoryStore.fail(historyRow, errorMessage: "Bee unreachable.")
            replyError(id: id, code: Code.nodeUnavailable,
                       message: "Bee unreachable.",
                       reason: Reason.nodeStopped)
        } catch {
            services.publishHistoryStore.fail(historyRow, errorMessage: "createFeed failed: \(error)")
            replyError(id: id, code: Code.internalError,
                       message: "createFeed failed: \(error)")
        }
    }

    /// `owner` accepts the internal unprefixed-lowercase form and is
    /// normalized to the SWIP wire format (EIP-55 checksummed `0x`) —
    /// the spec requires the same owner string across `createFeed`,
    /// `listFeeds`, `writeSingleOwnerChunk`, and `getSigningIdentity`.
    private static func createFeedResult(
        feedId: String, owner: String, topic: String,
        manifestRef: String, identityMode: String
    ) -> [String: Any] {
        [
            "feedId": feedId,
            "owner": Hex.checksummed(owner),
            "topic": topic,
            "manifestReference": manifestRef,
            "bzzUrl": "bzz://\(manifestRef)",
            "identityMode": identityMode,
        ]
    }

    // MARK: - swarm_updateFeed

    /// SWIP §"swarm_updateFeed". Per-topic serialization via
    /// `feedWriteLock` so two concurrent updates to the same feed
    /// can't both resolve the same "next" index — the second waits
    /// for the first to publish before reading.
    private func handleUpdateFeed(
        id: Int, origin: OriginIdentity, params: [String: Any]
    ) async {
        let Code = SwarmRouter.ErrorPayload.Code.self
        let Reason = SwarmRouter.ErrorPayload.Reason.self

        guard assertEligibleAndFree(id: id, origin: origin),
              requireConnectedOrigin(id: id, origin: origin) else { return }

        guard let feedId = params["feedId"] as? String,
              SwarmRouter.isValidFeedName(feedId) else {
            return replyError(id: id, code: Code.invalidParams,
                              message: "feedId must be 1-64 chars, no '/', no control chars.",
                              reason: Reason.invalidFeedName)
        }
        guard let reference = params["reference"] as? String,
              SwarmRef.isHex(reference, length: 64) else {
            return replyError(id: id, code: Code.invalidParams,
                              message: "reference must be a 64-character hex string.")
        }

        // Feed must exist locally — bee accepts any (owner, topic) but
        // SWIP §"Behavior" requires the dapp's feed to be registered
        // before update. Without a local record we have no manifest
        // reference to surface back as `bzzUrl` either.
        guard let record = services.feedStore.lookup(origin: origin.key, name: feedId) else {
            return replyError(id: id, code: Code.invalidParams,
                              message: "Feed not found: \(feedId).",
                              reason: Reason.feedNotFound)
        }
        guard let identity = services.feedStore.feedIdentity(origin: origin.key) else {
            return replyError(id: id, code: Code.internalError,
                              message: "Feed record without matching identity.")
        }

        guard requireCanPublish(id: id, origin: origin) else { return }

        // updateFeed is never a first grant — identity was chosen at
        // create-time, so auto-approve is eligible.
        let decision: ApprovalRequest.Decision
        if feedAutoApproveActive(origin: origin) {
            decision = .approved
        } else {
            decision = await parkAndAwait(
                origin: origin,
                kind: .swarmFeedAccess(SwarmFeedAccessDetails(
                    scope: .feed(name: feedId), isFirstGrant: false
                ))
            )
        }
        guard case .approved = decision else {
            return replyError(id: id, code: Code.userRejected,
                              message: "User rejected the request.")
        }

        let privateKey: Data
        do {
            privateKey = try identity.signingKey(via: services.vault)
        } catch {
            return replyError(id: id, code: Code.internalError,
                              message: "Couldn't derive feed signing key: \(error)")
        }

        guard let batch = StampService.selectBestBatch(
            forBytes: StampService.estimatedBytes(forFeedWrite: 0),
            in: services.currentStamps()
        ) else {
            return replyError(id: id, code: Code.nodeUnavailable,
                              message: "No usable stamp.",
                              reason: Reason.noUsableStamps)
        }

        let topicHex = record.topic
        let ownerHex = record.owner
        let historyRow = services.publishHistoryStore.record(
            kind: .feedUpdate, name: feedId, origin: origin.key
        )
        do {
            let result = try await services.feedWriteLock.withLock(topicHex: topicHex) { [services] in
                try await services.feedService.updateFeed(
                    ownerHex: ownerHex, topicHex: topicHex,
                    contentReference: reference,
                    privateKey: privateKey,
                    batchID: batch.batchID
                )
            }
            services.feedStore.updateReference(
                origin: origin.key, name: feedId, reference: reference
            )
            services.permissionStore.touchLastUsed(origin: origin.key)
            if let tagUid = result.tagUid {
                services.tagOwnership.record(tag: tagUid, origin: origin.key)
            }
            services.publishHistoryStore.complete(
                historyRow, reference: reference,
                tagUid: result.tagUid, batchId: batch.batchID
            )
            reply(id: id, result: [
                "feedId": feedId,
                "reference": reference,
                "bzzUrl": "bzz://\(record.manifestReference)",
                "index": Int(result.index),
            ])
        } catch SwarmFeedService.FeedServiceError.unreachable {
            services.publishHistoryStore.fail(historyRow, errorMessage: "Bee unreachable.")
            replyError(id: id, code: Code.nodeUnavailable,
                       message: "Bee unreachable.",
                       reason: Reason.nodeStopped)
        } catch {
            services.publishHistoryStore.fail(historyRow, errorMessage: "updateFeed failed: \(error)")
            replyError(id: id, code: Code.internalError,
                       message: "updateFeed failed: \(error)")
        }
    }

    // MARK: - swarm_writeFeedEntry

    /// SWIP §"swarm_writeFeedEntry" — journal pattern. Same gates as
    /// `handleUpdateFeed`; payload semantics differ (caller-supplied
    /// bytes rather than a 32-byte content reference) and the index
    /// can be auto-incremented or explicitly supplied (with overwrite
    /// protection at the SOC layer).
    private func handleWriteFeedEntry(
        id: Int, origin: OriginIdentity, params: [String: Any]
    ) async {
        let Code = SwarmRouter.ErrorPayload.Code.self
        let Reason = SwarmRouter.ErrorPayload.Reason.self

        guard assertEligibleAndFree(id: id, origin: origin),
              requireConnectedOrigin(id: id, origin: origin) else { return }

        guard let name = params["name"] as? String,
              SwarmRouter.isValidFeedName(name) else {
            return replyError(id: id, code: Code.invalidParams,
                              message: "name must be 1-64 chars, no '/', no control chars.",
                              reason: Reason.invalidFeedName)
        }

        let payload: Data
        do {
            payload = try Self.parseWriteFeedEntryData(params)
        } catch let SwarmRouter.RouterError.invalidParams(reason, message) {
            return replyError(id: id, code: Code.invalidParams,
                              message: message, reason: reason)
        } catch {
            return replyError(id: id, code: Code.internalError,
                              message: "\(error)")
        }

        let explicitIndex: UInt64?
        switch params["index"] {
        case nil, is NSNull:
            explicitIndex = nil
        case let int as Int where int >= 0:
            explicitIndex = UInt64(int)
        default:
            return replyError(id: id, code: Code.invalidParams,
                              message: "index must be a non-negative integer.")
        }

        guard let record = services.feedStore.lookup(origin: origin.key, name: name) else {
            return replyError(id: id, code: Code.invalidParams,
                              message: "Feed not found: \(name).",
                              reason: Reason.feedNotFound)
        }
        guard let identity = services.feedStore.feedIdentity(origin: origin.key) else {
            return replyError(id: id, code: Code.internalError,
                              message: "Feed record without matching identity.")
        }

        guard requireCanPublish(id: id, origin: origin) else { return }

        let decision: ApprovalRequest.Decision
        if feedAutoApproveActive(origin: origin) {
            decision = .approved
        } else {
            decision = await parkAndAwait(
                origin: origin,
                kind: .swarmFeedAccess(SwarmFeedAccessDetails(
                    scope: .feed(name: name), isFirstGrant: false
                ))
            )
        }
        guard case .approved = decision else {
            return replyError(id: id, code: Code.userRejected,
                              message: "User rejected the request.")
        }

        let privateKey: Data
        do {
            privateKey = try identity.signingKey(via: services.vault)
        } catch {
            return replyError(id: id, code: Code.internalError,
                              message: "Couldn't derive feed signing key: \(error)")
        }

        guard let batch = StampService.selectBestBatch(
            forBytes: StampService.estimatedBytes(forFeedWrite: payload.count),
            in: services.currentStamps()
        ) else {
            return replyError(id: id, code: Code.nodeUnavailable,
                              message: "No usable stamp.",
                              reason: Reason.noUsableStamps)
        }

        let topicHex = record.topic
        let ownerHex = record.owner
        let historyRow = services.publishHistoryStore.record(
            kind: .feedEntry, name: name, origin: origin.key,
            bytesSize: payload.count
        )
        do {
            let result = try await services.feedWriteLock.withLock(topicHex: topicHex) { [services] in
                try await services.feedService.writeFeedEntry(
                    ownerHex: ownerHex, topicHex: topicHex,
                    payload: payload,
                    explicitIndex: explicitIndex,
                    privateKey: privateKey,
                    batchID: batch.batchID
                )
            }
            services.permissionStore.touchLastUsed(origin: origin.key)
            if let tagUid = result.tagUid {
                services.tagOwnership.record(tag: tagUid, origin: origin.key)
            }
            services.publishHistoryStore.complete(
                historyRow, reference: result.socReference,
                tagUid: result.tagUid, batchId: batch.batchID
            )
            reply(id: id, result: ["index": Int(result.index)])
        } catch SwarmFeedService.FeedServiceError.indexAlreadyExists(let index) {
            services.publishHistoryStore.fail(
                historyRow, errorMessage: "Entry already exists at index \(index)."
            )
            replyError(id: id, code: Code.invalidParams,
                       message: "Entry already exists at index \(index).",
                       reason: Reason.indexAlreadyExists)
        } catch SwarmFeedService.FeedServiceError.unreachable {
            services.publishHistoryStore.fail(historyRow, errorMessage: "Bee unreachable.")
            replyError(id: id, code: Code.nodeUnavailable,
                       message: "Bee unreachable.",
                       reason: Reason.nodeStopped)
        } catch {
            services.publishHistoryStore.fail(historyRow, errorMessage: "writeFeedEntry failed: \(error)")
            replyError(id: id, code: Code.internalError,
                       message: "writeFeedEntry failed: \(error)")
        }
    }

    /// JS preload always base64-encodes `data` (strings are UTF-8'd
    /// then base64'd; binary is base64'd directly). Native side decodes
    /// to opaque bytes — SOC payload is encoding-agnostic.
    private static func parseWriteFeedEntryData(
        _ params: [String: Any]
    ) throws -> Data {
        guard let str = params["data"] as? String, !str.isEmpty else {
            throw SwarmRouter.RouterError.invalidParams(
                reason: nil, message: "data must not be empty."
            )
        }
        guard let bytes = Data(base64Encoded: str), !bytes.isEmpty else {
            throw SwarmRouter.RouterError.invalidParams(
                reason: nil, message: "data must be a base64-encoded string."
            )
        }
        // Same `maxDataBytes` cap as `swarm_publishData` — `writeFeedEntry`
        // wraps > 4 KB payloads via `/bytes`, so the dapp-visible limit
        // is the advertised one, not the SOC's internal 4 KB.
        let maxBytes = SwarmCapabilities.Limits.defaults.maxDataBytes
        if bytes.count > maxBytes {
            throw SwarmRouter.RouterError.invalidParams(
                reason: SwarmRouter.ErrorPayload.Reason.payloadTooLarge,
                message: "Payload exceeds \(maxBytes) bytes."
            )
        }
        return bytes
    }

    // MARK: - Chunk-tier params

    /// Chunk payload (`swarm_publishChunk` / `swarm_writeSingleOwnerChunk`
    /// `data`) — base64 from the JS preload, capped at the protocol's
    /// 4096 bytes (advertised as `maxChunkPayloadBytes`).
    private static func parseChunkData(_ params: [String: Any]) throws -> Data {
        guard let str = params["data"] as? String, !str.isEmpty,
              let bytes = Data(base64Encoded: str), !bytes.isEmpty else {
            throw SwarmRouter.RouterError.invalidParams(
                reason: nil, message: "data must be a non-empty base64-encoded string."
            )
        }
        if bytes.count > SwarmSOC.maxChunkPayloadSize {
            throw SwarmRouter.RouterError.invalidParams(
                reason: SwarmRouter.ErrorPayload.Reason.payloadTooLarge,
                message: "Payload exceeds \(SwarmSOC.maxChunkPayloadSize) bytes."
            )
        }
        return bytes
    }

    /// SWIP chunk-method `span`: non-negative integer ≤ 2⁶⁴ − 1. JS
    /// `number`s arrive as NSNumber (must be within the safe-integer
    /// range — beyond it the page MUST use `bigint`, which the preload
    /// forwards as a decimal string); strings parse as u64.
    private static func parseSpanParam(_ value: Any?) throws -> UInt64? {
        func invalid() -> SwarmRouter.RouterError {
            .invalidParams(
                reason: SwarmRouter.ErrorPayload.Reason.invalidSpan,
                message: "span must be a non-negative integer ≤ 2^64-1 "
                    + "(bigint above 2^53-1)."
            )
        }
        switch value {
        case nil, is NSNull:
            return nil
        case let int as Int:
            guard int >= 0, UInt64(int) <= SwarmChunkCodec.maxSafeJSInteger else {
                throw invalid()
            }
            return UInt64(int)
        case let str as String:
            guard let parsed = UInt64(str) else { throw invalid() }
            return parsed
        default:
            // Fractional Double, bool, object — all invalid.
            throw invalid()
        }
    }

    // MARK: - swarm_publishChunk

    /// SWIP §"swarm_publishChunk" — CAC upload under the publish
    /// permission tier: same gates, approval flow, and stamp selection
    /// as `swarm_publishData`, chunk-sized payload.
    private func handlePublishChunk(
        id: Int, origin: OriginIdentity, params: [String: Any]
    ) async {
        let Code = SwarmRouter.ErrorPayload.Code.self
        let Reason = SwarmRouter.ErrorPayload.Reason.self

        guard assertEligibleAndFree(id: id, origin: origin),
              requireConnectedOrigin(id: id, origin: origin) else { return }

        let payload: Data
        let span: UInt64?
        do {
            try SwarmRouter.requireEmptyOptions(params)
            payload = try Self.parseChunkData(params)
            span = try Self.parseSpanParam(params["span"])
        } catch let SwarmRouter.RouterError.invalidParams(reason, message) {
            return replyError(id: id, code: Code.invalidParams,
                              message: message, reason: reason)
        } catch {
            return replyError(id: id, code: Code.internalError,
                              message: "\(error)")
        }

        guard requireCanPublish(id: id, origin: origin) else { return }

        guard let batch = StampService.selectBestBatch(
            forBytes: payload.count,
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
                    sizeBytes: payload.count, mode: .chunk
                ))
            )
        }
        guard case .approved = decision else {
            return replyError(id: id, code: Code.userRejected,
                              message: "User rejected the request.")
        }

        let historyRow = services.publishHistoryStore.record(
            kind: .chunk, name: nil, origin: origin.key,
            bytesSize: payload.count
        )
        do {
            let result = try await services.chunkService.publishChunk(
                payload: payload, span: span, batchID: batch.batchID
            )
            recordPublishSuccess(tagUid: result.tagUid, origin: origin)
            services.publishHistoryStore.complete(
                historyRow, reference: result.reference,
                tagUid: result.tagUid, batchId: batch.batchID
            )
            reply(id: id, result: ["reference": result.reference])
        } catch SwarmChunkService.ChunkServiceError.unreachable {
            services.publishHistoryStore.fail(historyRow, errorMessage: "Bee unreachable.")
            replyError(id: id, code: Code.nodeUnavailable,
                       message: "Bee unreachable.",
                       reason: Reason.nodeStopped)
        } catch {
            services.publishHistoryStore.fail(historyRow, errorMessage: "publishChunk failed: \(error)")
            replyError(id: id, code: Code.internalError,
                       message: "publishChunk failed: \(error)")
        }
    }

    // MARK: - swarm_writeSingleOwnerChunk

    /// SWIP §"swarm_writeSingleOwnerChunk" — SOC write under the feed
    /// permission tier (signing shares key material with feeds). Same
    /// grant + approval flow as `swarm_writeFeedEntry`; no feed record
    /// is required, only the origin's signing identity.
    private func handleWriteSingleOwnerChunk(
        id: Int, origin: OriginIdentity, params: [String: Any]
    ) async {
        let Code = SwarmRouter.ErrorPayload.Code.self
        let Reason = SwarmRouter.ErrorPayload.Reason.self

        guard assertEligibleAndFree(id: id, origin: origin),
              requireConnectedOrigin(id: id, origin: origin) else { return }

        let identifierBytes: Data
        let payload: Data
        let span: UInt64?
        do {
            try SwarmRouter.requireEmptyOptions(params)
            guard let identifier = params["identifier"] as? String,
                  SwarmRef.isHex(identifier, length: 64),
                  let bytes = Data(hex: identifier.lowercased()),
                  bytes.count == 32 else {
                throw SwarmRouter.RouterError.invalidParams(
                    reason: Reason.invalidIdentifier,
                    message: "identifier must be a 64-character hex string."
                )
            }
            identifierBytes = bytes
            payload = try Self.parseChunkData(params)
            span = try Self.parseSpanParam(params["span"])
        } catch let SwarmRouter.RouterError.invalidParams(reason, message) {
            return replyError(id: id, code: Code.invalidParams,
                              message: message, reason: reason)
        } catch {
            return replyError(id: id, code: Code.internalError,
                              message: "\(error)")
        }

        guard requireCanPublish(id: id, origin: origin) else { return }

        // First grant always shows the sheet (identity-mode picker);
        // same contract as handleCreateFeed.
        let isFirstGrant = services.feedStore.feedIdentity(origin: origin.key) == nil
        let decision: ApprovalRequest.Decision
        if !isFirstGrant && feedAutoApproveActive(origin: origin) {
            decision = .approved
        } else {
            decision = await parkAndAwait(
                origin: origin,
                kind: .swarmFeedAccess(SwarmFeedAccessDetails(
                    scope: .signing, isFirstGrant: isFirstGrant
                ))
            )
        }
        guard case .approved = decision else {
            return replyError(id: id, code: Code.userRejected,
                              message: "User rejected the request.")
        }

        guard let identity = services.feedStore.feedIdentity(origin: origin.key) else {
            return replyError(id: id, code: Code.internalError,
                              message: "Feed identity missing after approval.")
        }
        let privateKey: Data
        do {
            privateKey = try identity.signingKey(via: services.vault)
        } catch {
            return replyError(id: id, code: Code.internalError,
                              message: "Couldn't derive signing key: \(error)")
        }

        guard let batch = StampService.selectBestBatch(
            forBytes: StampService.estimatedBytes(forFeedWrite: payload.count),
            in: services.currentStamps()
        ) else {
            return replyError(id: id, code: Code.nodeUnavailable,
                              message: "No usable stamp.",
                              reason: Reason.noUsableStamps)
        }

        let historyRow = services.publishHistoryStore.record(
            kind: .soc, name: nil, origin: origin.key,
            bytesSize: payload.count
        )
        do {
            let result = try await services.chunkService.writeSingleOwnerChunk(
                identifier: identifierBytes, payload: payload, span: span,
                privateKey: privateKey, batchID: batch.batchID
            )
            services.permissionStore.touchLastUsed(origin: origin.key)
            if let tagUid = result.tagUid {
                services.tagOwnership.record(tag: tagUid, origin: origin.key)
            }
            services.publishHistoryStore.complete(
                historyRow, reference: result.reference,
                tagUid: result.tagUid, batchId: batch.batchID
            )
            reply(id: id, result: [
                "reference": result.reference,
                "owner": Hex.checksummed(result.ownerHex),
                "identifier": identifierBytes.web3.hexString.web3.noHexPrefix,
            ])
        } catch SwarmChunkService.ChunkServiceError.unreachable {
            services.publishHistoryStore.fail(historyRow, errorMessage: "Bee unreachable.")
            replyError(id: id, code: Code.nodeUnavailable,
                       message: "Bee unreachable.",
                       reason: Reason.nodeStopped)
        } catch {
            services.publishHistoryStore.fail(historyRow, errorMessage: "writeSingleOwnerChunk failed: \(error)")
            replyError(id: id, code: Code.internalError,
                       message: "writeSingleOwnerChunk failed: \(error)")
        }
    }

    // MARK: - swarm_getSigningIdentity

    /// SWIP §"swarm_getSigningIdentity" — identity disclosure under the
    /// feed permission tier. Once the grant exists the method MUST
    /// return without prompting; before it exists, this is the
    /// bootstrap path for the same grant `swarm_createFeed` acquires.
    /// No node/stamp pre-flight — disclosure is a pure key operation
    /// (matches desktop).
    private func handleGetSigningIdentity(id: Int, origin: OriginIdentity) async {
        let Code = SwarmRouter.ErrorPayload.Code.self

        guard origin.isEligibleForWallet else {
            return replyError(id: id, code: Code.unauthorized,
                              message: "Origin not permitted.")
        }
        guard requireConnectedOrigin(id: id, origin: origin) else { return }

        if let identity = services.feedStore.feedIdentity(origin: origin.key) {
            // Grant exists — return without prompting when we can
            // resolve the owner. Deriving needs the unlocked vault;
            // with it locked, any existing feed record carries the
            // same owner (it's already public via swarm_listFeeds).
            if services.vault.state == .unlocked {
                return replySigningIdentity(id: id, origin: origin, identity: identity)
            }
            if let record = services.feedStore.all(forOrigin: origin.key).first {
                services.permissionStore.touchLastUsed(origin: origin.key)
                return reply(id: id, result: [
                    "owner": Hex.checksummed(record.owner),
                    "identityMode": identity.identityMode.rawValue,
                ])
            }
            // Locked vault, no feeds yet — the sheet's unlock strip is
            // the only way to resolve the key. Not a re-consent: the
            // sheet auto-approves post-unlock when auto-approve is on.
            guard assertEligibleAndFree(id: id, origin: origin) else { return }
            let decision = await parkAndAwait(
                origin: origin,
                kind: .swarmFeedAccess(SwarmFeedAccessDetails(
                    scope: .signing, isFirstGrant: false
                ))
            )
            guard case .approved = decision else {
                return replyError(id: id, code: Code.userRejected,
                                  message: "User rejected the request.")
            }
            return replySigningIdentity(id: id, origin: origin, identity: identity)
        }

        // No grant yet — acquire it (identity-mode picker on the sheet,
        // same first-grant flow as swarm_createFeed).
        guard assertEligibleAndFree(id: id, origin: origin) else { return }
        let decision = await parkAndAwait(
            origin: origin,
            kind: .swarmFeedAccess(SwarmFeedAccessDetails(
                scope: .signing, isFirstGrant: true
            ))
        )
        guard case .approved = decision else {
            return replyError(id: id, code: Code.userRejected,
                              message: "User rejected the request.")
        }
        guard let identity = services.feedStore.feedIdentity(origin: origin.key) else {
            return replyError(id: id, code: Code.internalError,
                              message: "Feed identity missing after approval.")
        }
        replySigningIdentity(id: id, origin: origin, identity: identity)
    }

    private func replySigningIdentity(
        id: Int, origin: OriginIdentity, identity: SwarmFeedIdentity
    ) {
        let ownerHex: String
        do {
            let privateKey = try identity.signingKey(via: services.vault)
            ownerHex = try FeedSigner.ownerAddressBytes(privateKey: privateKey)
                .web3.hexString.web3.noHexPrefix
        } catch {
            return replyError(
                id: id, code: SwarmRouter.ErrorPayload.Code.internalError,
                message: "Couldn't derive signing key: \(error)"
            )
        }
        services.permissionStore.touchLastUsed(origin: origin.key)
        reply(id: id, result: [
            "owner": Hex.checksummed(ownerHex),
            "identityMode": identity.identityMode.rawValue,
        ])
    }

    // MARK: - Messaging extension (SWIP messaging)

    /// Identity for subscription teardown — one bridge per tab, so
    /// this doubles as the tab key in the registry.
    private var subscriptionOwnerID: ObjectIdentifier { ObjectIdentifier(self) }

    /// SWIP messaging: subscriptions are session-scoped — the hosting
    /// tab calls this on navigation, page stop, and close.
    func cancelSubscriptions() {
        services.subscriptionRegistry.cancelByOwner(subscriptionOwnerID)
    }

    /// Messaging-tier gate. `true` when the grant exists; otherwise
    /// prompts (grant sheet) and persists on approval. The sheet's
    /// approve() writes the grant before resolving — same contract as
    /// the feed sheet. Replies 4001 and returns `false` on denial.
    private func requireMessagingGrant(
        id: Int, origin: OriginIdentity, operation: SwarmMessagingDetails.Operation
    ) async -> Bool {
        if services.permissionStore.hasMessagingGrant(origin.key) { return true }
        guard assertEligibleAndFree(id: id, origin: origin) else { return false }
        let decision = await parkAndAwait(
            origin: origin,
            kind: .swarmMessaging(SwarmMessagingDetails(
                operation: operation, isFirstGrant: true
            ))
        )
        guard case .approved = decision else {
            replyError(id: id, code: SwarmRouter.ErrorPayload.Code.userRejected,
                       message: "User rejected the request.")
            return false
        }
        guard services.permissionStore.hasMessagingGrant(origin.key) else {
            replyError(id: id, code: SwarmRouter.ErrorPayload.Code.internalError,
                       message: "Messaging grant missing after approval.")
            return false
        }
        return true
    }

    /// Desktop's `validateMessagingTopic`: non-empty string, ≤ 256
    /// UTF-8 bytes, no control characters.
    private static func validMessagingTopic(_ value: Any?) -> String? {
        guard let topic = value as? String, !topic.isEmpty,
              topic.utf8.count <= 256,
              topic.unicodeScalars.allSatisfy({ $0.value >= 32 }) else {
            return nil
        }
        return topic
    }

    /// Messaging payload: base64 from the preload (strings UTF-8'd
    /// there). PSS allows empty (trojan framing carries a length);
    /// GSOC rejects empty with `invalid_payload` (bee refuses an
    /// empty SOC payload).
    private static func parseMessagingPayload(
        _ params: [String: Any], emptyReason: String?
    ) throws -> Data {
        guard let str = params["data"] as? String,
              let bytes = Data(base64Encoded: str) else {
            throw SwarmRouter.RouterError.invalidParams(
                reason: nil, message: "data must be a base64-encoded string."
            )
        }
        if bytes.isEmpty, let emptyReason {
            throw SwarmRouter.RouterError.invalidParams(
                reason: emptyReason,
                message: "Payload must not be empty."
            )
        }
        let maxBytes = SwarmCapabilities.Limits.defaults.maxMessageBytes
        if bytes.count > maxBytes {
            throw SwarmRouter.RouterError.invalidParams(
                reason: SwarmRouter.ErrorPayload.Reason.payloadTooLarge,
                message: "Payload exceeds \(maxBytes) bytes."
            )
        }
        return bytes
    }

    // MARK: - swarm_getMessagingIdentity

    /// SWIP messaging §"swarm_getMessagingIdentity". Under the
    /// messaging tier; once granted it MUST return without prompting.
    private func handleGetMessagingIdentity(id: Int, origin: OriginIdentity) async {
        let Code = SwarmRouter.ErrorPayload.Code.self

        guard origin.isEligibleForWallet else {
            return replyError(id: id, code: Code.unauthorized,
                              message: "Origin not permitted.")
        }
        guard requireConnectedOrigin(id: id, origin: origin),
              await requireMessagingGrant(id: id, origin: origin, operation: .identity)
        else { return }

        do {
            let identity = try await services.messagingService.messagingIdentity()
            services.permissionStore.touchLastUsed(origin: origin.key)
            reply(id: id, result: [
                "pssPublicKey": identity.pssPublicKey,
                "pssTarget": identity.pssTarget,
                "identityMode": identity.identityMode,
            ])
        } catch SwarmMessagingService.MessagingError.unreachable {
            replyError(id: id, code: Code.nodeUnavailable,
                       message: "Bee unreachable.",
                       reason: SwarmRouter.ErrorPayload.Reason.nodeStopped)
        } catch {
            replyError(id: id, code: Code.internalError,
                       message: "getMessagingIdentity failed: \(error)")
        }
    }

    // MARK: - swarm_subscribe

    /// SWIP messaging §"swarm_subscribe". Params validate before the
    /// grant prompt (desktop order); the registry enforces the
    /// per-origin cap and surfaces node-pool exhaustion as a
    /// retryable 4900 distinct from `too_many_subscriptions`.
    private func handleSubscribe(
        id: Int, origin: OriginIdentity, params: [String: Any]
    ) async {
        let Code = SwarmRouter.ErrorPayload.Code.self
        let Reason = SwarmRouter.ErrorPayload.Reason.self

        guard origin.isEligibleForWallet else {
            return replyError(id: id, code: Code.unauthorized,
                              message: "Origin not permitted.")
        }
        guard requireConnectedOrigin(id: id, origin: origin) else { return }

        do {
            try SwarmRouter.requireEmptyOptions(params)
        } catch let SwarmRouter.RouterError.invalidParams(reason, message) {
            return replyError(id: id, code: Code.invalidParams,
                              message: message, reason: reason)
        } catch {
            return replyError(id: id, code: Code.internalError, message: "\(error)")
        }

        guard let kind = params["kind"] as? String, kind == "gsoc" || kind == "pss" else {
            return replyError(id: id, code: Code.invalidParams,
                              message: "kind must be \"gsoc\" or \"pss\".",
                              reason: Reason.invalidKind)
        }

        let hasTopic = !(params["topic"] == nil || params["topic"] is NSNull)
        let hasAddress = !(params["address"] == nil || params["address"] is NSNull)
        var topic: String?

        if kind == "gsoc" {
            guard hasTopic != hasAddress else {
                return replyError(
                    id: id, code: Code.invalidParams,
                    message: "Provide either topic or address, not both."
                )
            }
            if hasAddress {
                guard let address = params["address"] as? String,
                      SwarmRef.isHex(address, length: 64) else {
                    return replyError(id: id, code: Code.invalidParams,
                                      message: "address must be a 64-character hex string.",
                                      reason: Reason.invalidAddress)
                }
            }
        } else {
            guard !hasAddress else {
                return replyError(
                    id: id, code: Code.invalidParams,
                    message: "address is only valid for gsoc subscriptions."
                )
            }
            guard hasTopic else {
                return replyError(id: id, code: Code.invalidParams,
                                  message: "topic is required.",
                                  reason: Reason.invalidTopic)
            }
        }
        if hasTopic {
            guard let validTopic = Self.validMessagingTopic(params["topic"]) else {
                return replyError(id: id, code: Code.invalidParams,
                                  message: "topic must be a non-empty string ≤ 256 bytes, no control chars.",
                                  reason: Reason.invalidTopic)
            }
            topic = validTopic
        }

        guard await requireMessagingGrant(
            id: id, origin: origin,
            operation: .subscribe(topic: topic ?? (params["address"] as? String ?? ""))
        ) else { return }

        // Resolve the pipeline key: raw GSOC address, mined GSOC
        // derivation, or hashed PSS topic.
        let key: String
        if kind == "gsoc" {
            if let address = params["address"] as? String {
                key = address.lowercased()
            } else {
                do {
                    key = try await services.messagingService
                        .gsocDerivation(topic: topic!).addressHex
                } catch {
                    return replyError(id: id, code: Code.internalError,
                                      message: "GSOC derivation failed: \(error)")
                }
            }
        } else {
            key = SwarmMessagingService.pssTopicHex(topic!)
        }

        do {
            let subscriptionId = try await services.subscriptionRegistry.subscribe(
                origin: origin.key,
                owner: subscriptionOwnerID,
                kind: kind,
                key: key,
                deliver: { [weak self] payload in
                    self?.emit(event: "message", data: payload)
                }
            )
            services.permissionStore.touchLastUsed(origin: origin.key)
            reply(id: id, result: [
                "subscriptionId": subscriptionId,
                "kind": kind,
                "key": key,
            ])
        } catch SwarmSubscriptionRegistry.RegistryError.tooManySubscriptions {
            replyError(
                id: id, code: Code.invalidParams,
                message: "Subscription limit reached "
                    + "(\(SwarmCapabilities.Limits.defaults.maxSubscriptions) per site).",
                reason: Reason.tooManySubscriptions
            )
        } catch SwarmSubscriptionRegistry.RegistryError.nodeSubscriptionLimit {
            // Node-wide lurker pool exhausted — NOT a parameter error:
            // other origins' subscriptions caused it and it's
            // retryable once they close.
            replyError(id: id, code: Code.nodeUnavailable,
                       message: "Node subscription capacity exhausted — retry later.",
                       reason: Reason.nodeSubscriptionLimit)
        } catch {
            replyError(id: id, code: Code.nodeUnavailable,
                       message: "Bee unreachable.",
                       reason: Reason.nodeStopped)
        }
    }

    // MARK: - swarm_unsubscribe

    /// SWIP messaging §"swarm_unsubscribe" — never prompts.
    private func handleUnsubscribe(
        id: Int, origin: OriginIdentity, params: [String: Any]
    ) async {
        let Code = SwarmRouter.ErrorPayload.Code.self

        guard origin.isEligibleForWallet else {
            return replyError(id: id, code: Code.unauthorized,
                              message: "Origin not permitted.")
        }
        guard requireConnectedOrigin(id: id, origin: origin) else { return }

        guard let subscriptionId = params["subscriptionId"] as? String,
              !subscriptionId.isEmpty else {
            return replyError(id: id, code: Code.invalidParams,
                              message: "subscriptionId must be a non-empty string.")
        }
        guard services.subscriptionRegistry.unsubscribe(
            origin: origin.key, id: subscriptionId
        ) else {
            return replyError(
                id: id, code: Code.invalidParams,
                message: "No active subscription with that id.",
                reason: SwarmRouter.ErrorPayload.Reason.subscriptionNotFound
            )
        }
        reply(id: id, result: ["unsubscribed": true])
    }

    // MARK: - swarm_sendPss

    /// SWIP messaging §"swarm_sendPss" — messaging send tier: grant +
    /// per-send consent (or auto-approve), consumes a stamp. The node
    /// does trojan construction; empty payloads are valid.
    private func handleSendPss(
        id: Int, origin: OriginIdentity, params: [String: Any]
    ) async {
        let Code = SwarmRouter.ErrorPayload.Code.self
        let Reason = SwarmRouter.ErrorPayload.Reason.self

        guard origin.isEligibleForWallet else {
            return replyError(id: id, code: Code.unauthorized,
                              message: "Origin not permitted.")
        }
        guard requireConnectedOrigin(id: id, origin: origin) else { return }

        do {
            try SwarmRouter.requireEmptyOptions(params)
        } catch let SwarmRouter.RouterError.invalidParams(reason, message) {
            return replyError(id: id, code: Code.invalidParams,
                              message: message, reason: reason)
        } catch {
            return replyError(id: id, code: Code.internalError, message: "\(error)")
        }

        guard let topic = Self.validMessagingTopic(params["topic"]) else {
            return replyError(id: id, code: Code.invalidParams,
                              message: "topic must be a non-empty string ≤ 256 bytes, no control chars.",
                              reason: Reason.invalidTopic)
        }
        // 66-hex compressed secp256k1 key (0x-prefix tolerated).
        let recipientRaw = (params["recipient"] as? String ?? "")
        let recipient = recipientRaw.lowercased().hasPrefix("0x")
            ? String(recipientRaw.dropFirst(2)) : recipientRaw
        guard recipient.count == 66,
              recipient.hasPrefix("02") || recipient.hasPrefix("03"),
              SwarmRef.isHex(recipient, length: 66) else {
            return replyError(id: id, code: Code.invalidParams,
                              message: "recipient must be a 66-char hex compressed public key.",
                              reason: Reason.invalidRecipient)
        }
        let maxDepth = SwarmCapabilities.Limits.defaults.maxTargetDepth
        guard let targets = params["targets"] as? String,
              !targets.isEmpty, targets.count % 2 == 0,
              targets.count / 2 <= maxDepth,
              SwarmRef.isHex(targets, length: targets.count) else {
            return replyError(id: id, code: Code.invalidParams,
                              message: "targets must be 1–\(maxDepth) bytes of hex.",
                              reason: Reason.invalidTarget)
        }
        let payload: Data
        do {
            payload = try Self.parseMessagingPayload(params, emptyReason: nil)
        } catch let SwarmRouter.RouterError.invalidParams(reason, message) {
            return replyError(id: id, code: Code.invalidParams,
                              message: message, reason: reason)
        } catch {
            return replyError(id: id, code: Code.internalError, message: "\(error)")
        }

        guard await requireMessagingSendApproved(
            id: id, origin: origin,
            kind: .pss, topic: topic, sizeBytes: payload.count
        ) else { return }
        guard requireCanPublish(id: id, origin: origin) else { return }
        guard let batch = StampService.selectBestBatch(
            forBytes: SwarmSOC.maxChunkPayloadSize,
            in: services.currentStamps()
        ) else {
            return replyError(id: id, code: Code.nodeUnavailable,
                              message: "No usable stamp.",
                              reason: Reason.noUsableStamps)
        }

        do {
            try await services.messagingService.sendPss(
                topic: topic, targets: targets, recipient: recipient,
                payload: payload, batchID: batch.batchID
            )
            services.permissionStore.touchLastUsed(origin: origin.key)
            reply(id: id, result: ["sent": true])
        } catch SwarmMessagingService.MessagingError.unreachable {
            replyError(id: id, code: Code.nodeUnavailable,
                       message: "Bee unreachable.",
                       reason: Reason.nodeStopped)
        } catch {
            replyError(id: id, code: Code.internalError,
                       message: "sendPss failed: \(error)")
        }
    }

    // MARK: - swarm_sendGsoc

    /// SWIP messaging §"swarm_sendGsoc". No raw-address variant — the
    /// signing key only falls out of the topic derivation.
    private func handleSendGsoc(
        id: Int, origin: OriginIdentity, params: [String: Any]
    ) async {
        let Code = SwarmRouter.ErrorPayload.Code.self
        let Reason = SwarmRouter.ErrorPayload.Reason.self

        guard origin.isEligibleForWallet else {
            return replyError(id: id, code: Code.unauthorized,
                              message: "Origin not permitted.")
        }
        guard requireConnectedOrigin(id: id, origin: origin) else { return }

        do {
            try SwarmRouter.requireEmptyOptions(params)
        } catch let SwarmRouter.RouterError.invalidParams(reason, message) {
            return replyError(id: id, code: Code.invalidParams,
                              message: message, reason: reason)
        } catch {
            return replyError(id: id, code: Code.internalError, message: "\(error)")
        }

        // An address alone carries nothing to sign with — reject
        // explicitly so dapps learn the contract (desktop parity).
        guard params["address"] == nil || params["address"] is NSNull else {
            return replyError(
                id: id, code: Code.invalidParams,
                message: "sendGsoc takes a topic, not an address — "
                    + "the signing key derives from the topic.",
                reason: Reason.invalidAddress
            )
        }
        guard let topic = Self.validMessagingTopic(params["topic"]) else {
            return replyError(id: id, code: Code.invalidParams,
                              message: "topic must be a non-empty string ≤ 256 bytes, no control chars.",
                              reason: Reason.invalidTopic)
        }
        let payload: Data
        do {
            payload = try Self.parseMessagingPayload(
                params, emptyReason: SwarmRouter.ErrorPayload.Reason.invalidPayload
            )
        } catch let SwarmRouter.RouterError.invalidParams(reason, message) {
            return replyError(id: id, code: Code.invalidParams,
                              message: message, reason: reason)
        } catch {
            return replyError(id: id, code: Code.internalError, message: "\(error)")
        }

        guard await requireMessagingSendApproved(
            id: id, origin: origin,
            kind: .gsoc, topic: topic, sizeBytes: payload.count
        ) else { return }
        guard requireCanPublish(id: id, origin: origin) else { return }
        guard let batch = StampService.selectBestBatch(
            forBytes: SwarmSOC.maxChunkPayloadSize,
            in: services.currentStamps()
        ) else {
            return replyError(id: id, code: Code.nodeUnavailable,
                              message: "No usable stamp.",
                              reason: Reason.noUsableStamps)
        }

        do {
            let address = try await services.messagingService.sendGsoc(
                topic: topic, payload: payload, batchID: batch.batchID
            )
            services.permissionStore.touchLastUsed(origin: origin.key)
            reply(id: id, result: ["sent": true, "address": address])
        } catch SwarmMessagingService.MessagingError.unreachable {
            replyError(id: id, code: Code.nodeUnavailable,
                       message: "Bee unreachable.",
                       reason: Reason.nodeStopped)
        } catch {
            replyError(id: id, code: Code.internalError,
                       message: "sendGsoc failed: \(error)")
        }
    }

    /// Send-tier consent: tier grant (first use — the grant sheet also
    /// covers this send), then per-send prompt unless auto-approve.
    private func requireMessagingSendApproved(
        id: Int, origin: OriginIdentity,
        kind: SwarmMessagingDetails.SendKind, topic: String, sizeBytes: Int
    ) async -> Bool {
        let operation = SwarmMessagingDetails.Operation.send(
            kind: kind, topic: topic, sizeBytes: sizeBytes
        )
        if !services.permissionStore.hasMessagingGrant(origin.key) {
            // Grant sheet doubles as consent for this first send.
            return await requireMessagingGrant(id: id, origin: origin, operation: operation)
        }
        if services.permissionStore.isAutoApproveMessaging(origin: origin.key) {
            return true
        }
        guard assertEligibleAndFree(id: id, origin: origin) else { return false }
        let decision = await parkAndAwait(
            origin: origin,
            kind: .swarmMessaging(SwarmMessagingDetails(
                operation: operation, isFirstGrant: false
            ))
        )
        guard case .approved = decision else {
            replyError(id: id, code: SwarmRouter.ErrorPayload.Code.userRejected,
                       message: "User rejected the request.")
            return false
        }
        return true
    }

    // MARK: - Reply path

    private func reply(id: Int, result: Any) {
        replies.reply(id: id, result: result)
    }

    private func reply(id: Int, error: SwarmRouter.ErrorPayload) {
        var dict: [String: Any] = ["code": error.code, "message": error.message]
        if let reason = error.dataReason {
            dict["data"] = ["reason": reason]
        }
        replies.reply(id: id, errorObject: dict)
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

    private func emit(event: String, data: Any) {
        replies.emit(event: event, data: data)
    }
}

extension BrowserTab: SwarmBridgeHost {}
extension BridgeReplyChannel: SwarmBridgeReplies {}
