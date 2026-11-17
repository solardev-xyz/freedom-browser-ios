import Foundation
import IPFSKit
import MyotisKit
import OSLog
import RadicleKit
import SwarmKit

private let log = Logger(subsystem: "com.browser.Freedom", category: "AgentEngine")

/// Freedom's nodes as the agent's tools see them.
@MainActor
struct AgentNodes {
    let swarm: SwarmNode
    let readiness: BeeReadiness
    let stamps: StampService
    let swarmServices: SwarmServices
    let ipfs: IPFSNode
    let radicle: RadicleNode
    let myotis: MyotisNode
}

/// The engine's `nodes` service: desktop's node_status, node_request,
/// node_diagnostics, swarm_publish and swarm_publication_status, on the
/// phone's nodes. Approvals happen in the engine before a call reaches
/// here (agent.js nodeGate); `publishPreview` gives that approval what it
/// shows.
@MainActor
final class AgentNodeDriver {
    enum DriverError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { switch self { case .invalid(let message): message } }
    }

    private let nodes: AgentNodes
    private let attachments: AgentAttachmentStore
    private let defaults: UserDefaults
    private static let publicationsKey = "agent.chatPublications"
    /// Publications each chat made (publish history record IDs).
    private var publications: [String: [String]]

    init(nodes: AgentNodes, attachments: AgentAttachmentStore, defaults: UserDefaults = .standard) {
        self.nodes = nodes
        self.attachments = attachments
        self.defaults = defaults
        publications = defaults.dictionary(forKey: Self.publicationsKey) as? [String: [String]] ?? [:]
    }

    func handle(_ method: String, _ params: [String: Any]) async throws -> Any? {
        let chat = (params["chatId"] as? NSNumber)?.stringValue ?? params["chatId"] as? String
        switch method {
        case "status": return status()
        case "request": return try await request(params)
        case "diagnostics": return diagnostics(params)
        case "publishPreview": return try await preview(params, chat: chat)
        case "publish": return try await publish(params, chat: chat)
        case "publicationStatus": return await publicationStatus(params, chat: chat)
        default: throw AgentEngine.EngineError.tool("Unknown nodes method: \(method)")
        }
    }

    func forget(chatID: Int) {
        publications[String(chatID)] = nil
        defaults.set(publications, forKey: Self.publicationsKey)
    }

    func forgetAll() {
        publications = [:]
        defaults.set(publications, forKey: Self.publicationsKey)
        defaults.removeObject(forKey: Self.metaKey)
    }

    // MARK: - Status

    private func status() -> [String: Any] {
        ["swarm": swarmStatus(), "ipfs": ipfsStatus(), "radicle": radicleStatus(), "myotis": myotisStatus()]
    }

    private func swarmStatus() -> [String: Any] {
        let swarm = nodes.swarm
        let readiness: String = switch nodes.readiness.state {
        case .initializing: "initializing"
        case .startingUp: "starting up"
        case .syncingPostage(let percent, _, _): "syncing postage (\(percent)%)"
        case .ready: "ready"
        }
        var status: [String: Any] = [
            "service": "ant",
            "status": swarm.status.rawValue,
            "readiness": readiness,
            "peers": swarm.peerCount,
            "storage": nodes.stamps.stamps.map { batch -> [String: Any] in
                var item: [String: Any] = [
                    "batchId": batch.batchID, "usable": batch.usable, "depth": batch.depth,
                    "ttlDays": (Double(batch.ttlSeconds) / 86_400 * 10).rounded() / 10,
                    "usagePercent": Int((batch.usage * 100).rounded()), "effectiveBytes": batch.effectiveBytes,
                ]
                if let label = batch.label { item["label"] = label }
                return item
            },
        ]
        if let scan = swarm.walletScan, scan.state != "done" { status["lookingForOwnedStorage"] = scan.state }
        if let reason = nodes.swarmServices.nodeFailureReason() { status["cannotPublishBecause"] = reason }
        return status
    }

    private func ipfsStatus() -> [String: Any] {
        ["service": "ipfs", "status": nodes.ipfs.status.rawValue, "routing": String(describing: nodes.ipfs.activeRoutingMode), "httpApi": false]
    }

    private func radicleStatus() -> [String: Any] {
        var status: [String: Any] = ["service": "radicle", "status": nodes.radicle.status.rawValue, "peers": nodes.radicle.connectedPeers]
        if let alias = nodes.radicle.identity?.alias { status["alias"] = alias }
        if let error = nodes.radicle.lastError { status["lastError"] = error }
        return status
    }

    private func myotisStatus() -> [String: Any] {
        var chains: [String: Any] = [:]
        for (name, id) in [("ethereum", UInt64(1)), ("gnosis", UInt64(100))] {
            guard let chain = nodes.myotis.chainStatus[id] else { chains[name] = ["running": false]; continue }
            var item: [String: Any] = [
                "running": chain.running, "ready": nodes.myotis.isReady(chainId: id), "peers": chain.peerCount,
                "finalizedBlock": chain.finalizedBlockNumber, "latestBlock": chain.executionBlockNumber,
            ]
            if !chain.notServingReason.isEmpty { item["notServingReason"] = chain.notServingReason }
            chains[name] = item
        }
        return ["service": "myotis", "status": nodes.myotis.status.rawValue, "chains": chains]
    }

    // MARK: - Raw requests (Ant's Bee-compatible API)

    private static let blockedHeaders: Set<String> = ["authorization", "cookie", "host", "origin", "proxy-authorization", "referer"]
    private static let maxResponseBytes = 64 * 1024

    private func request(_ params: [String: Any]) async throws -> [String: Any] {
        guard params["service"] as? String == "ant" else {
            throw DriverError.invalid("CAPABILITY_UNAVAILABLE: IPFS on iPhone has no HTTP API. Use node_status.")
        }
        guard nodes.swarm.status == .running else { throw DriverError.invalid("NODE_NOT_RUNNING: the Swarm node isn't running.") }
        let spec = params["request"] as? [String: Any] ?? [:]
        let method = (spec["method"] as? String ?? "GET").uppercased()
        let path = spec["path"] as? String ?? ""
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains(where: \.isNewline),
              let url = URL(string: "http://\(SwarmNode.gatewayAuthority)\(path)") else {
            throw DriverError.invalid("INVALID_ARGUMENT: the path must be an absolute API path such as /stamps.")
        }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = method
        for (name, value) in spec["headers"] as? [String: String] ?? [:] {
            let lower = name.lowercased()
            guard !Self.blockedHeaders.contains(lower), lower.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil else {
                throw DriverError.invalid("INVALID_ARGUMENT: the header \(name) isn't allowed.")
            }
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body = spec["body"] as? String { request.httpBody = Data(body.utf8) }
        log.notice("[nodes] \(method, privacy: .public) \(path, privacy: .public)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            let readOnly = method == "GET" || method == "HEAD"
            throw DriverError.invalid(readOnly
                ? "NODE_UNREACHABLE: \(error.localizedDescription)"
                : "DELIVERY_UNCERTAIN: \(error.localizedDescription) The node may have applied the request; check its state (for example GET /stamps) before trying anything again.")
        }
        let http = response as? HTTPURLResponse
        var result: [String: Any] = ["status": http?.statusCode ?? 0, "bytes": data.count]
        if let type = http?.value(forHTTPHeaderField: "Content-Type") { result["contentType"] = type }
        let shown = data.prefix(Self.maxResponseBytes)
        if let text = String(data: shown, encoding: .utf8) {
            result["body"] = text
            if data.count > shown.count { result["truncated"] = true }
        } else {
            result["body"] = "(binary, \(data.count) bytes)"
        }
        return result
    }

    // MARK: - Diagnostics

    private func diagnostics(_ params: [String: Any]) -> [String: Any] {
        let service = params["service"] as? String ?? ""
        let maxLines = min(400, (params["maxLines"] as? NSNumber)?.intValue ?? 200)
        let maxBytes = min(65_536, (params["maxBytes"] as? NSNumber)?.intValue ?? 32_768)
        let (lines, status): ([String], [String: Any]) = switch service {
        case "ant": (nodes.swarm.log, swarmStatus())
        case "ipfs": (nodes.ipfs.log, ipfsStatus())
        case "radicle": (nodes.radicle.lastError.map { [$0] } ?? [], radicleStatus())
        default: (nodes.myotis.log, myotisStatus())
        }
        var kept: [String] = []
        var bytes = 0
        // Paths stay on the phone: the app's home folder becomes ~.
        let home = NSHomeDirectory()
        for raw in lines.suffix(maxLines).reversed() {
            let line = raw.replacingOccurrences(of: home, with: "~")
            bytes += line.utf8.count + 1
            if bytes > maxBytes { break }
            kept.insert(line, at: 0)
        }
        return ["service": service, "status": status, "lines": kept, "truncated": kept.count < lines.count]
    }

    // MARK: - Publishing

    private struct Payload {
        let data: Data
        let contentType: String
        /// An attachment's name; inline text has none.
        let name: String?
    }

    /// What a publication asks for besides its content (desktop's target and stableAddress).
    private struct Target {
        /// A private draft link: uploaded with Swarm encryption, the link carries the key.
        let draft: Bool
        /// A stable address's name (public publications only).
        let stableName: String?
    }

    private static let stableNamePattern = /[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?/
    /// Desktop's feed topic prefix: the same name gives the same address on both.
    private static let stableTopicPrefix = "freedom-agent/stable-address/"

    private func target(_ params: [String: Any]) throws -> Target {
        let raw = params["target"] as? String ?? "public"
        guard raw == "public" || raw == "draft" else { throw DriverError.invalid("INVALID_ARGUMENT: target must be one of: public, draft") }
        let stable = (params["stableAddress"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let stable {
            guard stable.wholeMatch(of: Self.stableNamePattern) != nil else {
                throw DriverError.invalid("INVALID_ARGUMENT: stableAddress must be 1-64 lowercase letters, digits or inner hyphens")
            }
            guard raw != "draft" else { throw DriverError.invalid("INVALID_ARGUMENT: A private draft link cannot have a stable address") }
        }
        return Target(draft: raw == "draft", stableName: stable)
    }

    private func payload(_ params: [String: Any], chat: String?) throws -> Payload {
        let resourceId = params["resourceId"] as? String
        let text = params["text"] as? String
        guard (resourceId == nil) != (text == nil) else { throw DriverError.invalid("INVALID_ARGUMENT: pass exactly one of resourceId or text.") }
        if let text {
            return Payload(data: Data(text.utf8), contentType: params["contentType"] as? String ?? "text/plain; charset=utf-8", name: nil)
        }
        guard let chat, let file = attachments.file(chat: chat, id: resourceId ?? "") else {
            throw DriverError.invalid("RESOURCE_NOT_FOUND: no attachment with that ID in this chat. Use attachment_list.")
        }
        return Payload(data: file.data, contentType: params["contentType"] as? String ?? file.attachment.mimeType, name: file.attachment.name)
    }

    /// The usable batch for `bytes`, or why there's none.
    private func batch(for bytes: Int) throws -> PostageBatch {
        if let reason = nodes.swarmServices.nodeFailureReason() { throw DriverError.invalid("NODE_NOT_READY: \(reason)") }
        guard let batch = StampService.selectBestBatch(forBytes: bytes, in: nodes.stamps.stamps) else {
            throw DriverError.invalid("NO_USABLE_POSTAGE: Freedom has no usable Swarm storage for \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)). Read the swarm-postage skill.")
        }
        return batch
    }

    /// Room for a stable address's feed entry and manifest besides the content.
    private static let stableAddressBytes = 2 * StampService.estimatedBytes(forFeedWrite: 0)

    private func preview(_ params: [String: Any], chat: String?) async throws -> [String: Any] {
        let target = try target(params)
        let payload = try payload(params, chat: chat)
        let identity = try target.stableName.map(stableIdentity)
        let batch = try batch(for: payload.data.count + (identity == nil ? 0 : Self.stableAddressBytes))
        let size = ByteCountFormatter.string(fromByteCount: Int64(payload.data.count), countStyle: .file)
        let what = payload.name.map { "“\($0)” (\(size))" } ?? "text (\(size), \(payload.contentType))"
        let days = batch.ttlSeconds / 86_400
        let storage = "\(batch.label.map { "“\($0)”" } ?? "storage \(batch.batchID.prefix(8))…"), \(days) days left, \(Int((batch.usage * 100).rounded()))% used"
        var notices: [String] = []
        if target.draft {
            notices.append("Private draft link. The content is encrypted, but anyone who gets the link can read it, so share it deliberately. The encrypted data is still stored on the public network and can’t be deleted or taken back.")
        } else {
            notices.append("This will be public. Anyone with the link can read it, and it can’t be deleted or taken back.")
        }
        if let identity, let name = target.stableName {
            let plan = await stablePlan(identity, name: name)
            var line = "Stable address “\(name)”, owned by your Swarm identity \(identity.owner.prefix(6))…\(identity.owner.suffix(4)). "
            switch plan.existing {
            case "yes":
                line += "This address already exists\(plan.currentBzzUrl.map { " (\($0))" } ?? ""). Publishing points it at this content, and anything linked to it, such as an ENS name, will show this publication."
            case "no": line += "This creates a new address."
            default: line += "Freedom couldn’t check whether this address exists yet; publishing points it at this content either way."
            }
            notices.append(line)
            notices.append("Later fixes can update this address, but they don’t remove this version: anyone holding its own reference can still retrieve it while its postage is valid.")
        }
        let action = target.draft ? "Create a private draft link for \(what) on Swarm." : "Publish \(what) publicly to Swarm."
        return [
            "what": what,
            "summary": "\(action) \(notices.joined(separator: " ")) Uses \(storage).",
            "warnings": days < 7 ? ["storage_expires_soon"] : [String](),
        ]
    }

    private static let origin = "freedom://agent"

    private func publish(_ params: [String: Any], chat: String?) async throws -> [String: Any] {
        let target = try target(params)
        let payload = try payload(params, chat: chat)
        let identity = try target.stableName.map(stableIdentity)
        let batch = try batch(for: payload.data.count + (identity == nil ? 0 : Self.stableAddressBytes))
        let history = nodes.swarmServices.publishHistoryStore
        let historyName = target.draft ? "\(payload.name ?? "Text") (private draft link)" : payload.name
        let row = history.record(kind: .data, name: historyName, origin: Self.origin, bytesSize: payload.data.count)
        var meta: [String: Any] = ["target": target.draft ? "draft" : "public"]
        if let chat {
            publications[chat, default: []].append(row.id.uuidString)
            defaults.set(publications, forKey: Self.publicationsKey)
        }
        defer { saveMeta(meta, for: row.id) }
        let upload: SwarmPublishService.UploadResult
        do {
            upload = try await nodes.swarmServices.publishService.publishData(
                payload.data, contentType: payload.contentType, name: payload.name, batchID: batch.batchID, encrypt: target.draft
            )
        } catch {
            let message = SwarmUserPublisher.describe(error)
            history.fail(row, errorMessage: message)
            throw DriverError.invalid("PUBLISH_FAILED: \(message)")
        }
        let reference = upload.reference.lowercased()
        if target.draft, reference.wholeMatch(of: /[0-9a-f]{64}/) != nil {
            // The node ignored Swarm-Encrypt: this content is public now.
            meta["unencryptedReference"] = reference
            let message = "The node did not encrypt this upload: it returned the unencrypted reference \(reference). Treat the content as public, and do not share it as a private draft link."
            history.fail(row, errorMessage: message)
            throw DriverError.invalid("PUBLISH_FAILED: \(message)")
        }
        guard reference.wholeMatch(of: target.draft ? /[0-9a-f]{128}/ : /[0-9a-f]{64}/) != nil else {
            let message = "The node returned an unexpected reference."
            history.fail(row, errorMessage: message)
            throw DriverError.invalid("PUBLISH_FAILED: \(message)")
        }
        history.complete(row, reference: reference, tagUid: upload.tagUid, batchId: batch.batchID)
        log.notice("[nodes] published \(payload.data.count) bytes\(target.draft ? " encrypted" : "", privacy: .public)")
        // Follow the upload tag for up to a minute; the reference is final either way.
        var sent = upload.tagUid == nil
        if let tag = upload.tagUid {
            for _ in 0..<30 {
                if let progress = try? await nodes.swarmServices.bee.getTag(uid: tag), progress.isDone {
                    sent = true
                    break
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        if let identity, let name = target.stableName {
            meta["stableAddress"] = await updateStableAddress(identity, name: name, reference: reference, batchID: batch.batchID)
        }
        saveMeta(meta, for: row.id)
        return receipt(row, sending: !sent)
    }

    // MARK: - Stable addresses

    /// The Swarm identity a stable address's feed belongs to: the node wallet key
    /// (m/44'/60'/0'/0/1), as on desktop, so an address is the same on both.
    private struct StableIdentity {
        /// 0x-prefixed lowercase address.
        let owner: String
        let ownerHex: String
        let privateKey: Data
        let topicHex: String
    }

    private func stableIdentity(_ name: String) throws -> StableIdentity {
        let address: String
        let key: HDKey
        do {
            key = try nodes.swarmServices.vault.signingKey(at: .beeWallet)
            address = try key.ethereumAddress.lowercased()
        } catch {
            throw DriverError.invalid("CAPABILITY_UNAVAILABLE: A stable address is signed with your Swarm identity, which needs Freedom’s vault unlocked. Ask the user to unlock it, then publish again.")
        }
        let hex = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
        return StableIdentity(owner: "0x" + hex, ownerHex: hex, privateKey: key.privateKey, topicHex: FeedTopic.fromString(Self.stableTopicPrefix + name))
    }

    private static let stableAddressesKey = "agent.stableAddresses"

    /// Stable addresses this phone updated: `owner/name` → manifest reference and last index.
    private var stableAddresses: [String: [String: Any]] {
        get { defaults.dictionary(forKey: Self.stableAddressesKey) as? [String: [String: Any]] ?? [:] }
        set { defaults.set(newValue, forKey: Self.stableAddressesKey) }
    }

    private struct StablePlan {
        /// "yes", "no" or "unknown".
        let existing: String
        let latestIndex: UInt64?
        let currentBzzUrl: String?
    }

    /// Whether the address exists, from this phone's record or the network (10 s at most).
    private func stablePlan(_ identity: StableIdentity, name: String) async -> StablePlan {
        if let known = stableAddresses["\(identity.owner)/\(name)"], let manifest = known["manifest"] as? String {
            return StablePlan(existing: "yes", latestIndex: (known["index"] as? NSNumber)?.uint64Value, currentBzzUrl: "bzz://\(manifest)")
        }
        let service = nodes.swarmServices.feedService
        do {
            // nil: no entry 0, so no address yet. (`try?` would flatten that into a failure.)
            let latest: UInt64? = try await Self.within(seconds: 10) {
                do {
                    return try await service.readFeed(identity.ownerHex, identity.topicHex, nil).index
                } catch BeeAPIClient.Error.notFound {
                    return try await service.latestIndex(ownerHex: identity.ownerHex, topicHex: identity.topicHex)
                }
            }
            return latest.map { StablePlan(existing: "yes", latestIndex: $0, currentBzzUrl: nil) }
                ?? StablePlan(existing: "no", latestIndex: nil, currentBzzUrl: nil)
        } catch {
            return StablePlan(existing: "unknown", latestIndex: nil, currentBzzUrl: nil)
        }
    }

    /// Points the stable address at `reference`: a feed update (after any later entry
    /// the node finds), then the feed manifest whose reference is the address. The
    /// content stays published if this fails; the receipt says so.
    private func updateStableAddress(_ identity: StableIdentity, name: String, reference: String, batchID: String) async -> [String: Any] {
        var result: [String: Any] = ["name": name, "owner": identity.owner]
        let key = "\(identity.owner)/\(name)"
        let known = (stableAddresses[key]?["index"] as? NSNumber)?.uint64Value
        let service = nodes.swarmServices.feedService
        let lock = nodes.swarmServices.feedWriteLock
        let write: @MainActor (UInt64) async throws -> SwarmFeedService.FeedWriteResult = { minIndex in
            try await Self.within(seconds: 60) {
                try await lock.withLock(topicHex: identity.topicHex) {
                    try await service.updateFeed(
                        ownerHex: identity.ownerHex, topicHex: identity.topicHex, contentReference: reference,
                        privateKey: identity.privateKey, batchID: batchID, minIndex: minIndex, probeHead: true
                    )
                }
            }
        }
        do {
            var written = try await write(known.map { $0 + 1 } ?? 0)
            // A later entry the node only found now: write once more after it.
            if let head = try? await service.readFeed(identity.ownerHex, identity.topicHex, nil).index, head > written.index {
                written = try await write(head + 1)
            }
            let manifest = try await Self.within(seconds: 60) {
                try await service.createFeed(ownerHex: identity.ownerHex, topicHex: identity.topicHex, batchID: batchID)
            }
            stableAddresses[key] = ["manifest": manifest.manifestReference, "index": NSNumber(value: written.index)]
            result["reference"] = manifest.manifestReference
            result["bzzUrl"] = manifest.bzzUrl
            result["index"] = NSNumber(value: written.index)
            result["updated"] = true
            log.notice("[nodes] stable address \(name, privacy: .public) now at index \(written.index)")
        } catch {
            result["updated"] = false
            result["error"] = "The stable address was not updated: \(SwarmUserPublisher.describe(error))"
            log.error("[nodes] stable address \(name, privacy: .public) not updated: \(String(describing: error), privacy: .public)")
        }
        return result
    }

    private struct Timeout: LocalizedError {
        var errorDescription: String? { "The Swarm node didn't answer in time." }
    }

    /// `work`'s result, or `Timeout` after `seconds` (the work is cancelled).
    private static func within<T: Sendable>(seconds: Double, _ work: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw Timeout()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Timeout() }
            return first
        }
    }

    // MARK: - Receipts

    private static let metaKey = "agent.publicationMeta"

    /// Per publication (history record ID): target, stable address result, an unencrypted reference.
    private func saveMeta(_ meta: [String: Any], for id: UUID) {
        var all = defaults.dictionary(forKey: Self.metaKey) ?? [:]
        all[id.uuidString] = meta
        defaults.set(all, forKey: Self.metaKey)
    }

    private func meta(for id: UUID) -> [String: Any] {
        (defaults.dictionary(forKey: Self.metaKey)?[id.uuidString] as? [String: Any]) ?? [:]
    }

    private func publicationID(_ id: UUID) -> String { "swarm_pub_" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    private func receipt(_ row: SwarmPublishHistoryRecord, sending: Bool) -> [String: Any] {
        let meta = meta(for: row.id)
        let draft = meta["target"] as? String == "draft"
        var receipt: [String: Any] = ["publicationId": publicationID(row.id), "target": draft ? "draft" : "public", "public": !draft]
        if draft { receipt["encrypted"] = true }
        switch row.status {
        case .uploading: receipt["status"] = "uploading"
        case .failed: receipt["status"] = "failed"
        case .completed: receipt["status"] = sending ? "sending" : "sent"
        }
        if let reference = row.reference {
            receipt["reference"] = reference
            receipt["bzzUrl"] = "bzz://\(reference)/"
        }
        if let unencrypted = meta["unencryptedReference"] { receipt["unencryptedReference"] = unencrypted }
        if let stable = meta["stableAddress"] { receipt["stableAddress"] = stable }
        if let name = row.name { receipt["name"] = name }
        if let bytes = row.bytesSize { receipt["bytes"] = bytes }
        if let error = row.errorMessage { receipt["error"] = error }
        return receipt
    }

    private func publicationStatus(_ params: [String: Any], chat: String?) async -> [String: Any] {
        let history = nodes.swarmServices.publishHistoryStore
        let ids = (chat.flatMap { publications[$0] } ?? []).compactMap(UUID.init(uuidString:))
        if let wanted = params["publicationId"] as? String, !wanted.isEmpty {
            guard let id = ids.first(where: { publicationID($0) == wanted }), let row = history.entry(id: id) else {
                return ["error": "No publication with that ID in this chat."]
            }
            var sending = false
            if let tag = row.tagUid, let progress = try? await nodes.swarmServices.bee.getTag(uid: tag) { sending = !progress.isDone }
            return receipt(row, sending: sending)
        }
        return ["publications": ids.suffix(10).compactMap { history.entry(id: $0) }.map { receipt($0, sending: false) }]
    }
}
