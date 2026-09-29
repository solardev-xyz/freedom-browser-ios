import Foundation
import OSLog

private let log = Logger(subsystem: "com.browser.Freedom", category: "TezosDomains")

/// Outcome of resolving a `.tez` name — desktop's result object.
enum TezosResolution: Equatable {
    case ok(TezosDomains.WebsiteRecord, trust: ENSTrust)
    /// Unregistered, expired, or no website record.
    case notFound(reason: String)
    /// The record exists but the browser cannot follow it.
    case unsupported(reason: String)
    /// Providers disagree about the head, the anchor block or the record.
    case conflict(reason: String, groups: [ENSConflictGroup], trust: ENSTrust)
    /// No provider could be asked.
    case error(reason: String)
}

enum TezosDomainsError: Swift.Error, Equatable {
    case notFound(reason: String)
    case unsupported(reason: String)
    case unavailable(reason: String)
    /// The name publishes an HTTP(S) website, so a content-scheme
    /// request (`ipfs://name.tez/...`) cannot be served.
    case notContent(URL)
}

/// Native Tezos Domains resolution — desktop's `tezos-domains-resolver.js`.
/// Reads the mainnet registry through three public Tezos RPC endpoints:
/// every provider is pinned to one anchor block (the lowest plausible
/// head minus eight), the registry's proxy → contract → big-map ids are
/// discovered from the on-chain scripts, the name's record and expiry
/// are read at that block, and a strict majority of matching answers is
/// what marks a result verified.
@MainActor
final class TezosDomainsResolver {
    /// A raw HTTP exchange: status code and body. Injected by tests.
    typealias Fetch = @Sendable (URLRequest) async throws -> (status: Int, body: Data)

    static let mainnetChainID = "NetXdQprcVkpaWU"
    static let proxyContract = "KT1F7JKNqwaoLzRsMio1MQC7zv3jG9dHcDdJ"
    static let defaultEndpoints: [URL] = [
        URL(string: "https://tezos-mainnet.octez.io")!,
        URL(string: "https://rpc.tzkt.io/mainnet")!,
        URL(string: "https://rpc.tzbeta.net")!,
    ]
    static let requestTimeout: TimeInterval = 8
    static let anchorDepth = 8
    /// A head more than this far from the median is stale or lying.
    static let maxHeadLagBlocks = 60
    static let defaultTTL: TimeInterval = 5 * 60
    static let maxTTL: TimeInterval = 60 * 60
    static let negativeTTL: TimeInterval = 30
    static let unverifiedTTL: TimeInterval = 30
    static let discoveryTTL: TimeInterval = 10 * 60
    static let maxResponseBytes = 5 * 1024 * 1024
    static let maxCachedNames = 500

    private struct Discovery {
        let recordsID: String
        let expiryMapID: String
        let recordType: [String: Any]?
    }

    private struct Head { let endpoint: URL; let level: Int }
    private struct Anchor { let endpoint: URL; let level: Int; let hash: String }

    /// One provider's answer for a name at the anchor block.
    private enum Leg: Equatable {
        case ok(TezosDomains.WebsiteRecord)
        case notFound(reason: String, expiry: String?)
        case unsupported(reason: String)

        /// Desktop `semanticResultKey`: what has to agree for two
        /// providers to count as one answer.
        var key: String {
            switch self {
            case .ok(let r): "ok|\(r.kind)|\(r.uri.absoluteString)|\(r.decoded ?? "")|\(r.basePath)|\(r.redirect)|\(r.expiry ?? "")|\(r.ttl.map(String.init) ?? "")"
            case .notFound(let reason, let expiry): "not_found|\(reason)|\(expiry ?? "")"
            case .unsupported(let reason): "unsupported|\(reason)"
            }
        }
    }

    private let endpoints: [URL]
    private let fetch: Fetch
    private let now: () -> Date
    private var results: [String: (resolution: TezosResolution, expiresAt: Date)] = [:]
    private var discoveries: [URL: (discovery: Discovery, expiresAt: Date)] = [:]
    private var inflight: [String: Task<TezosResolution, Never>] = [:]

    init(endpoints: [URL] = TezosDomainsResolver.defaultEndpoints, fetch: Fetch? = nil, now: @escaping () -> Date = Date.init) {
        self.endpoints = Array(endpoints.prefix(3))
        self.fetch = fetch ?? Self.urlSessionFetch
        self.now = now
    }

    static let urlSessionFetch: Fetch = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    // MARK: - Public

    func resolve(_ name: String) async -> TezosResolution {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard TezosDomains.isName(normalized) else { return .notFound(reason: "invalid .tez domain") }
        if let cached = results[normalized], cached.expiresAt > now() { return cached.resolution }
        results[normalized] = nil
        if let running = inflight[normalized] { return await running.value }
        let task = Task { await self.resolveUncached(normalized) }
        inflight[normalized] = task
        let resolution = await task.value
        inflight[normalized] = nil
        return resolution
    }

    func invalidate(name: String? = nil) {
        if let name {
            results[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = nil
        } else {
            results.removeAll()
            discoveries.removeAll()
        }
    }

    // MARK: - Quorum

    private func resolveUncached(_ name: String) async -> TezosResolution {
        let allHeads = await settled(endpoints) { try await self.fetchHead($0) }
        guard !allHeads.isEmpty else { return .error(reason: "all Tezos RPC providers failed") }

        // Median-referenced outlier rejection, then a strict-majority
        // rule: with two responders that disagree the median is just
        // the lower one, so neither side is trustworthy.
        let levels = allHeads.map(\.level).sorted()
        let reference = levels[(levels.count - 1) / 2]
        let heads = allHeads.filter { head in
            let keep = abs(head.level - reference) <= Self.maxHeadLagBlocks
            if !keep { log.warning("excluding \(head.endpoint.host ?? "", privacy: .public): head \(head.level) deviates from median \(reference)") }
            return keep
        }
        if heads.count * 2 <= allHeads.count { return headConflict(allHeads, retained: heads.count) }

        let anchorLevel = heads.map(\.level).min()! - Self.anchorDepth
        let anchors = await settled(heads) { try await self.fetchAnchor($0.endpoint, level: anchorLevel) }
        guard !anchors.isEmpty else { return .error(reason: "Tezos RPC providers could not anchor a block") }
        var anchorGroups: [String: [Anchor]] = [:]
        for anchor in anchors { anchorGroups["\(anchor.level):\(anchor.hash)", default: []].append(anchor) }
        let bestAnchors = anchorGroups.values.max { $0.count < $1.count }!
        if bestAnchors.count * 2 <= anchors.count {
            return anchorConflict(Array(anchorGroups.values), retained: bestAnchors.count)
        }

        let legs = await settled(bestAnchors) { anchor -> (endpoint: URL, leg: Leg) in
            (anchor.endpoint, try await self.resolveAtBlock(anchor.endpoint, blockHash: anchor.hash, name: name))
        }
        guard !legs.isEmpty else { return .error(reason: "Tezos Domains registry lookup failed") }

        var groups: [String: [(endpoint: URL, leg: Leg)]] = [:]
        var order: [String] = []
        for leg in legs {
            if groups[leg.leg.key] == nil { order.append(leg.leg.key) }
            groups[leg.leg.key, default: []].append(leg)
        }
        let sorted = order.map { groups[$0]! }.sorted { $0.count > $1.count }
        let winner = sorted[0]
        let block = ENSBlock(number: UInt64(max(0, bestAnchors[0].level)), hash: bestAnchors[0].hash)
        let hosts = { (legs: [(endpoint: URL, leg: Leg)]) in legs.map { Self.host($0.endpoint) } }

        if sorted.count > 1, winner.count * 2 <= legs.count {
            let trust = ENSTrust(
                level: .conflict, system: .tezos, method: .quorum, block: block,
                agreed: [], dissented: [], queried: hosts(legs), k: legs.count, m: winner.count
            )
            return .conflict(
                reason: "Tezos RPC providers returned conflicting results",
                groups: sorted.map { group in Self.conflictGroup(group[0].leg, hosts: hosts(group)) },
                trust: trust
            )
        }

        let level: ENSTrustLevel = winner.count >= 2 ? .verified : .unverified
        let dissenting = legs.filter { leg in !winner.contains { $0.endpoint == leg.endpoint } }
        if !dissenting.isEmpty {
            log.warning("\(dissenting.map { Self.host($0.endpoint) }.joined(separator: ", "), privacy: .public) disagreed with the majority for \(name, privacy: .public)")
        }
        let trust = ENSTrust(
            level: level, system: .tezos, method: .quorum, block: block,
            agreed: hosts(winner), dissented: hosts(dissenting), queried: hosts(legs), k: legs.count, m: winner.count
        )
        let resolution: TezosResolution
        switch winner[0].leg {
        case .ok(let record): resolution = .ok(record, trust: trust)
        case .notFound(let reason, _): resolution = .notFound(reason: reason)
        case .unsupported(let reason): resolution = .unsupported(reason: reason)
        }
        results[name] = (resolution, now().addingTimeInterval(cacheDuration(resolution)))
        if results.count > Self.maxCachedNames, let oldest = results.min(by: { $0.value.expiresAt < $1.value.expiresAt }) {
            results[oldest.key] = nil
        }
        return resolution
    }

    private func headConflict(_ heads: [Head], retained: Int) -> TezosResolution {
        var byLevel: [Int: [String]] = [:]
        for head in heads { byLevel[head.level, default: []].append(Self.host(head.endpoint)) }
        let trust = ENSTrust(
            level: .conflict, system: .tezos, method: .quorum, block: ENSBlock(number: 0, hash: ""),
            agreed: [], dissented: [], queried: heads.map { Self.host($0.endpoint) }, k: heads.count, m: retained
        )
        return .conflict(
            reason: "Tezos RPC providers disagree about the chain head",
            groups: byLevel.keys.sorted().map { ENSConflictGroup(resolvedData: nil, reason: nil, hosts: byLevel[$0]!, value: "chain head #\($0)") },
            trust: trust
        )
    }

    private func anchorConflict(_ groups: [[Anchor]], retained: Int) -> TezosResolution {
        let total = groups.reduce(0) { $0 + $1.count }
        let trust = ENSTrust(
            level: .conflict, system: .tezos, method: .quorum, block: ENSBlock(number: 0, hash: ""),
            agreed: [], dissented: [], queried: groups.flatMap { $0.map { Self.host($0.endpoint) } }, k: total, m: retained
        )
        return .conflict(
            reason: "Tezos RPC providers returned conflicting anchor blocks",
            groups: groups.sorted { $0.count > $1.count }.map { group in
                let hash = group[0].hash
                return ENSConflictGroup(
                    resolvedData: nil, reason: nil, hosts: group.map { Self.host($0.endpoint) },
                    value: "block #\(group[0].level) \(hash.prefix(10))…\(hash.suffix(4))"
                )
            },
            trust: trust
        )
    }

    private static func conflictGroup(_ leg: Leg, hosts: [String]) -> ENSConflictGroup {
        switch leg {
        case .ok(let record):
            let uri = record.uri.absoluteString
            return ENSConflictGroup(resolvedData: nil, reason: nil, hosts: hosts, value: uri.count > 300 ? String(uri.prefix(300)) + "…" : uri)
        case .notFound(let reason, _), .unsupported(let reason):
            return ENSConflictGroup(resolvedData: nil, reason: nil, hosts: hosts, value: reason)
        }
    }

    private func cacheDuration(_ resolution: TezosResolution) -> TimeInterval {
        guard case .ok(let record, let trust) = resolution else { return Self.negativeTTL }
        if trust.level != .verified { return Self.unverifiedTTL }
        var duration = record.ttl.map { $0 > 0 ? TimeInterval($0) : Self.defaultTTL } ?? Self.defaultTTL
        duration = min(duration, Self.maxTTL)
        if let expiry = record.expiry.flatMap(Self.parseDate) {
            duration = min(duration, max(0, expiry.timeIntervalSince(now())))
        }
        return max(1, duration)
    }

    // MARK: - Providers

    private func fetchHead(_ endpoint: URL) async throws -> Head {
        async let chainID = rpc(endpoint, "/chains/main/chain_id")
        async let header = rpc(endpoint, "/chains/main/blocks/head/header")
        guard try await chainID as? String == Self.mainnetChainID else { throw ProviderError("unexpected Tezos chain") }
        guard let level = ((try await header) as? [String: Any])?["level"] as? Int, level > Self.anchorDepth else {
            throw ProviderError("invalid Tezos head level")
        }
        return Head(endpoint: endpoint, level: level)
    }

    private func fetchAnchor(_ endpoint: URL, level: Int) async throws -> Anchor {
        guard let hash = try await rpc(endpoint, "/chains/main/blocks/\(level)/hash") as? String, hash.hasPrefix("B") else {
            throw ProviderError("invalid Tezos block hash")
        }
        return Anchor(endpoint: endpoint, level: level, hash: hash)
    }

    private func resolveAtBlock(_ endpoint: URL, blockHash: String, name: String) async throws -> Leg {
        if let cached = discoveries[endpoint], cached.expiresAt > now() {
            if let leg = try? await lookupRecord(endpoint, blockHash: blockHash, name: name, discovery: cached.discovery) {
                return leg
            }
            // Stale ids (registry migration) or a transient failure —
            // rediscover once before failing the leg.
            discoveries[endpoint] = nil
        }
        let discovery = try await discoverRegistry(endpoint, blockHash: blockHash)
        discoveries[endpoint] = (discovery, now().addingTimeInterval(Self.discoveryTTL))
        return try await lookupRecord(endpoint, blockHash: blockHash, name: name, discovery: discovery)
    }

    private func discoverRegistry(_ endpoint: URL, blockHash: String) async throws -> Discovery {
        let proxy = try await normalizedScript(endpoint, blockHash: blockHash, contract: Self.proxyContract)
        let contract = TezosDomains.findAnnotatedValue(
            type: TezosDomains.storageType(fromScript: proxy), value: (proxy as? [String: Any])?["storage"], annotation: "%contract"
        )?.value
        guard let registry = (contract as? [String: Any])?["string"] as? String,
              registry.range(of: #"^KT1[1-9A-HJ-NP-Za-km-z]{33}$"#, options: .regularExpression) != nil else {
            throw ProviderError("Tezos Domains proxy returned an invalid registry contract")
        }
        let script = try await normalizedScript(endpoint, blockHash: blockHash, contract: registry)
        let storageType = TezosDomains.storageType(fromScript: script)
        let storage = (script as? [String: Any])?["storage"]
        let records = TezosDomains.findAnnotatedValue(type: storageType, value: storage, annotation: "%records")
        let expiry = TezosDomains.findAnnotatedValue(type: storageType, value: storage, annotation: "%expiry_map")
        guard let recordsID = (records?.value as? [String: Any])?["int"] as? String, recordsID.allSatisfy(\.isNumber),
              let expiryID = (expiry?.value as? [String: Any])?["int"] as? String, expiryID.allSatisfy(\.isNumber) else {
            throw ProviderError("Tezos Domains registry storage is missing annotated big maps")
        }
        let recordType = (records?.type["args"] as? [Any])?.dropFirst().first as? [String: Any]
        return Discovery(recordsID: recordsID, expiryMapID: expiryID, recordType: recordType)
    }

    private func lookupRecord(_ endpoint: URL, blockHash: String, name: String, discovery: Discovery) async throws -> Leg {
        let key = TezosDomains.scriptExprHash(Data(name.utf8))
        guard let record = try await rpc(endpoint, "/chains/main/blocks/\(Self.encode(blockHash))/context/big_maps/\(discovery.recordsID)/\(key)") else {
            return .notFound(reason: "domain record not found", expiry: nil)
        }
        let data = TezosDomains.findAnnotatedValue(type: discovery.recordType, value: record, annotation: "%data")?.value
        let expiryKey = TezosDomains.findAnnotatedValue(type: discovery.recordType, value: record, annotation: "%expiry_key")?.value as? [String: Any]

        var expiry: String?
        if expiryKey?["prim"] as? String == "Some", let hex = ((expiryKey?["args"] as? [Any])?.first as? [String: Any])?["bytes"],
           let keyBytes = TezosDomains.bytes(fromHex: hex) {
            let expiryRecord = try await rpc(endpoint, "/chains/main/blocks/\(Self.encode(blockHash))/context/big_maps/\(discovery.expiryMapID)/\(TezosDomains.scriptExprHash(keyBytes))")
            guard let date = (expiryRecord as? [String: Any])?["string"] as? String else {
                throw ProviderError("Tezos Domains expiry record is missing")
            }
            expiry = date
            if let expiresAt = Self.parseDate(date), expiresAt <= now() {
                return .notFound(reason: "domain record expired", expiry: date)
            }
        }

        let entries = TezosDomains.mapEntries(data)
        func string(_ key: String) throws -> String? {
            guard let hex = entries[key] else { return nil }
            guard let value = TezosDomains.decodeJSONBytes(hex) as? String else { throw ProviderError("invalid Tezos Domains metadata: \(key)") }
            return value
        }
        let redirectURL: String?
        let contentURL: String?
        var ttl: Int?
        do {
            redirectURL = try string("web:redirect_url")
            contentURL = try string("web:content_url")
            if let hex = entries["td:ttl"] {
                guard let number = TezosDomains.decodeJSONBytes(hex) as? NSNumber else { throw ProviderError("invalid Tezos Domains metadata: td:ttl") }
                ttl = number.intValue
            }
        } catch {
            return .unsupported(reason: (error as? ProviderError)?.message ?? "invalid Tezos Domains metadata")
        }

        func finish(_ parse: TezosDomains.RecordParse) -> Leg {
            switch parse {
            case .ok(var record):
                record.expiry = expiry
                record.ttl = ttl
                return .ok(record)
            case .unsupported(let reason):
                return .unsupported(reason: reason)
            }
        }
        if let redirectURL { return finish(TezosDomains.parsePublishedURI(redirectURL, redirect: true)) }
        if let contentURL { return finish(TezosDomains.parsePublishedURI(contentURL)) }
        return .notFound(reason: "domain has no website record", expiry: expiry)
    }

    private func normalizedScript(_ endpoint: URL, blockHash: String, contract: String) async throws -> Any? {
        try await rpc(
            endpoint, "/chains/main/blocks/\(Self.encode(blockHash))/context/contracts/\(contract)/script/normalized",
            method: "POST", body: Data(#"{"unparsing_mode":"Readable"}"#.utf8)
        )
    }

    /// One Tezos RPC request; nil for a 404 (the common answer for an
    /// unregistered name), a thrown error for anything else.
    private func rpc(_ endpoint: URL, _ path: String, method: String = "GET", body: Data? = nil) async throws -> Any? {
        guard let url = URL(string: endpoint.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw ProviderError("invalid RPC URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Self.requestTimeout
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        let (status, data) = try await fetch(request)
        if status == 404 { return nil }
        guard (200...299).contains(status) else { throw ProviderError("RPC returned HTTP \(status)") }
        guard data.count <= Self.maxResponseBytes else { throw ProviderError("RPC response exceeded the size limit") }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private struct ProviderError: Swift.Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Run `work` for every element concurrently; failures are dropped.
    private func settled<T, R: Sendable>(_ items: [T], _ work: @escaping @MainActor (T) async throws -> R) async -> [R] where T: Sendable {
        await withTaskGroup(of: (Int, R?).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask { @MainActor in (index, try? await work(item)) }
            }
            var out: [(Int, R)] = []
            for await (index, value) in group { if let value { out.append((index, value)) } }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }

    static func host(_ url: URL) -> String { url.host ?? url.absoluteString }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ value: String) -> Date? {
        isoFormatter.date(from: value) ?? {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: value)
        }()
    }
}
