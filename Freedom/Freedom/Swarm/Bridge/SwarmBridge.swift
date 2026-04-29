import Foundation
import web3
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
    /// SWIP §"swarm_getUploadStatus": "Tag not found or not owned by
    /// this origin." Used both when the tag was never recorded under
    /// this origin and when bee evicted it; same desktop wording.
    private static let tagNotOwnedMessage = "Tag not found or not owned by this origin."

    private weak var tab: BrowserTab?
    private let router: SwarmRouter
    private let services: SwarmServices
    /// Weak: `WKUserContentController.add(_:name:)` strongly retains us,
    /// so this side of the edge must not retain back — otherwise tab
    /// teardown would never run.
    private weak var contentController: WKUserContentController?
    private let replies: BridgeReplyChannel

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
        self.replies = BridgeReplyChannel(
            jsGlobal: "__freedomSwarm", webView: tab.webView
        )
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
        case "swarm_publishFiles":
            await handlePublishFiles(id: id, origin: origin, params: params)
            return
        case "swarm_getUploadStatus":
            await handleGetUploadStatus(id: id, origin: origin, params: params)
            return
        case "swarm_createFeed":
            await handleCreateFeed(id: id, origin: origin, params: params)
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
        guard tab?.pendingSwarmApproval == nil else {
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
                    mode: .data(contentType: parsed.contentType, name: parsed.name)
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
                recordPublishSuccess(tagUid: result.tagUid, origin: origin)
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

        let caps = router.capabilities(origin: origin)
        if !caps.canPublish {
            let reason = caps.reason ?? Reason.nodeNotReady
            return replyError(id: id, code: Code.nodeUnavailable,
                              message: "Node not ready: \(reason)",
                              reason: reason)
        }

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
            do {
                let result = try await services.publishService.publishFiles(
                    tarBytes,
                    indexDocument: parsed.indexDocument,
                    batchID: batch.batchID
                )
                recordPublishSuccess(tagUid: result.tagUid, origin: origin)
                reply(id: id, result: [
                    "reference": result.reference,
                    "bzzUrl": "bzz://\(result.reference)",
                    "tagUid": result.tagUid as Any? ?? NSNull(),
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
    /// rejecting the upload mid-stream. The 100-char cap matches USTAR
    /// (no PAX); SWIP allows up to 256, tracked as a divergence.
    private static func validateVirtualPath(_ path: String, index: Int) throws {
        if path.isEmpty {
            throw SwarmRouter.RouterError.invalidParams(
                reason: nil, message: "files[\(index)].path is empty."
            )
        }
        // USTAR's 100 is a *byte* limit on the header field; multi-byte
        // UTF-8 chars count toward it. `String.count` (Characters) would
        // miss the difference and let through paths that silently
        // truncate inside `TarBuilder.header`.
        if path.utf8.count > 100 {
            throw SwarmRouter.RouterError.invalidParams(
                reason: nil,
                message: "files[\(index)].path exceeds 100-byte USTAR limit."
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
            tag = try await services.bee.getTag(uid: tagUid)
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

        let caps = router.capabilities(origin: origin)
        if !caps.canPublish {
            let reason = caps.reason ?? Reason.nodeNotReady
            return replyError(id: id, code: Code.nodeUnavailable,
                              message: "Node not ready: \(reason)",
                              reason: reason)
        }

        // First grant always shows the sheet so the user can pick the
        // identity mode; auto-approve only kicks in for subsequent
        // grants once the mode is locked.
        let isFirstGrant = services.feedStore.feedIdentity(origin: origin.key) == nil
        let decision: ApprovalRequest.Decision
        if !isFirstGrant && services.permissionStore.isAutoApproveFeeds(origin: origin.key) {
            decision = .approved
        } else {
            decision = await parkAndAwait(
                origin: origin,
                kind: .swarmFeedAccess(SwarmFeedAccessDetails(
                    feedName: name, isFirstGrant: isFirstGrant
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

        // Manifest is a single small chunk; 4 KB capacity fits with
        // headroom. Matches desktop's createFeed estimate.
        guard let batch = StampService.selectBestBatch(
            forBytes: 4096, in: services.currentStamps()
        ) else {
            return replyError(id: id, code: Code.nodeUnavailable,
                              message: "No usable stamp.",
                              reason: Reason.noUsableStamps)
        }

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
            reply(id: id, result: Self.createFeedResult(
                feedId: name, owner: ownerHex, topic: topicHex,
                manifestRef: result.manifestReference,
                identityMode: identity.identityMode.rawValue
            ))
        } catch SwarmFeedService.FeedServiceError.unreachable {
            replyError(id: id, code: Code.nodeUnavailable,
                       message: "Bee unreachable.",
                       reason: Reason.nodeStopped)
        } catch {
            replyError(id: id, code: Code.internalError,
                       message: "createFeed failed: \(error)")
        }
    }

    private static func createFeedResult(
        feedId: String, owner: String, topic: String,
        manifestRef: String, identityMode: String
    ) -> [String: Any] {
        [
            "feedId": feedId,
            "owner": owner,
            "topic": topic,
            "manifestReference": manifestRef,
            "bzzUrl": "bzz://\(manifestRef)",
            "identityMode": identityMode,
        ]
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
