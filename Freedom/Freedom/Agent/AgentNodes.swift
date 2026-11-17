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
        case "publishPreview": return try preview(params, chat: chat)
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

    private func payload(_ params: [String: Any], chat: String?) throws -> Payload {
        if params["target"] as? String == "draft" {
            throw DriverError.invalid("CAPABILITY_UNAVAILABLE: private draft links aren't available on iPhone yet; publishing is public only.")
        }
        if let stable = params["stableAddress"] as? String, !stable.isEmpty {
            throw DriverError.invalid("CAPABILITY_UNAVAILABLE: stable addresses aren't available on iPhone yet.")
        }
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

    private func preview(_ params: [String: Any], chat: String?) throws -> [String: Any] {
        let payload = try payload(params, chat: chat)
        let batch = try batch(for: payload.data.count)
        let size = ByteCountFormatter.string(fromByteCount: Int64(payload.data.count), countStyle: .file)
        let what = payload.name.map { "“\($0)” (\(size))" } ?? "text (\(size), \(payload.contentType))"
        let days = batch.ttlSeconds / 86_400
        let storage = "\(batch.label.map { "“\($0)”" } ?? "storage \(batch.batchID.prefix(8))…"), \(days) days left, \(Int((batch.usage * 100).rounded()))% used"
        return [
            "what": what,
            "summary": "Publish \(what) publicly to Swarm: anyone with the link can read it, and it can't be deleted while the storage lasts. Uses \(storage).",
            "warnings": days < 7 ? ["storage_expires_soon"] : [String](),
        ]
    }

    private static let origin = "freedom://agent"

    private func publish(_ params: [String: Any], chat: String?) async throws -> [String: Any] {
        let payload = try payload(params, chat: chat)
        let batch = try batch(for: payload.data.count)
        let history = nodes.swarmServices.publishHistoryStore
        let row = history.record(kind: .data, name: payload.name, origin: Self.origin, bytesSize: payload.data.count)
        if let chat {
            publications[chat, default: []].append(row.id.uuidString)
            defaults.set(publications, forKey: Self.publicationsKey)
        }
        let upload: SwarmPublishService.UploadResult
        do {
            upload = try await nodes.swarmServices.publishService.publishData(payload.data, contentType: payload.contentType, name: payload.name, batchID: batch.batchID)
        } catch {
            let message = SwarmUserPublisher.describe(error)
            history.fail(row, errorMessage: message)
            throw DriverError.invalid("PUBLISH_FAILED: \(message)")
        }
        history.complete(row, reference: upload.reference, tagUid: upload.tagUid, batchId: batch.batchID)
        log.notice("[nodes] published \(payload.data.count) bytes")
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
        return receipt(row, sending: !sent)
    }

    private func publicationID(_ id: UUID) -> String { "swarm_pub_" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    private func receipt(_ row: SwarmPublishHistoryRecord, sending: Bool) -> [String: Any] {
        var receipt: [String: Any] = ["publicationId": publicationID(row.id), "target": "public"]
        switch row.status {
        case .uploading: receipt["status"] = "uploading"
        case .failed: receipt["status"] = "failed"
        case .completed: receipt["status"] = sending ? "sending" : "sent"
        }
        if let reference = row.reference {
            receipt["reference"] = reference
            receipt["bzzUrl"] = "bzz://\(reference)/"
        }
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
