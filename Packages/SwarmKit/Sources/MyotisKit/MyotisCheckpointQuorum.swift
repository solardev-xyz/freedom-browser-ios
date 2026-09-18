import Foundation

/// Stale-anchor recovery, part 2: the external checkpoint quorum. Port
/// of desktop `checkpoint-verifier-worker.js` `checkpointVote` /
/// `checkpointQuorum` / `fetchBytes` — same endpoints, same evidence
/// rules, same replacement rule, same error classes.
///
/// Trust model (desktop parity): each authority votes once for a
/// `(slot, root)` only after explicitly endorsing finality — a block-root
/// answer alone is never a vote. A quorum is `threshold` agreeing votes
/// out of `participants` seats filled in stable candidate order; only
/// availability-class failures free a seat for the next reserve, so
/// dissent and contradictory evidence keep their seat and the threshold
/// is never lowered because a host is missing.

/// One agreed checkpoint: what the quorum endorsed for a slot.
public struct MyotisCheckpointObservation: Sendable, Equatable {
    public var slot: UInt64
    public var root: String
    public var finalizedEpoch: UInt64
    public var sources: [String]

    public init(slot: UInt64, root: String, finalizedEpoch: UInt64, sources: [String]) {
        self.slot = slot
        self.root = root
        self.finalizedEpoch = finalizedEpoch
        self.sources = sources
    }
}

/// Bounded HTTP for the recovery path. Implementations MUST: refuse
/// redirects, require status 200, cap the *streamed* body at `limit`
/// bytes (Content-Length alone is not enough), time out per request,
/// and throw `MyotisCheckpointError.unavailable` for every transport
/// failure. Injected so the quorum logic is unit-testable offline.
public protocol MyotisCheckpointFetcher: Sendable {
    func fetch(_ request: URLRequest, limit: Int) async throws -> Data
}

/// `URLSession`-backed fetcher. Ephemeral session (no cookies, no
/// cache — recovery must observe live answers), redirects refused via
/// the task delegate, streamed byte cap, 20 s per request.
public final class MyotisURLSessionFetcher: NSObject, MyotisCheckpointFetcher, URLSessionTaskDelegate,
    @unchecked Sendable
{
    public static let requestSeconds: TimeInterval = 20
    private let session: URLSession

    public override init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.requestSeconds
        config.timeoutIntervalForResource = Self.requestSeconds
        config.waitsForConnectivity = false
        config.httpShouldSetCookies = false
        config.urlCache = nil
        session = URLSession(configuration: config)
        super.init()
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Refuse: the 3xx surfaces as a non-200 response below.
        completionHandler(nil)
    }

    public func fetch(_ request: URLRequest, limit: Int) async throws -> Data {
        var request = request
        request.timeoutInterval = Self.requestSeconds
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: self)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw MyotisCheckpointError.unavailable
            }
            if http.expectedContentLength >= 0, http.expectedContentLength > Int64(limit) {
                throw MyotisCheckpointError.unavailable
            }
            var data = Data()
            data.reserveCapacity(min(limit, Int(max(0, http.expectedContentLength))))
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { throw MyotisCheckpointError.unavailable }
            }
            return data
        } catch let error as MyotisCheckpointError {
            throw error
        } catch {
            throw MyotisCheckpointError.unavailable
        }
    }
}

/// The quorum client for one network.
public struct MyotisCheckpointQuorum: Sendable {
    public static let maxMetadataBytes = 64 * 1024

    public let network: MyotisCheckpointNetwork
    public let fetcher: MyotisCheckpointFetcher
    /// Injectable clock (ms since the epoch).
    public let nowMs: @Sendable () -> Int64

    public init(
        network: MyotisCheckpointNetwork,
        fetcher: MyotisCheckpointFetcher,
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.network = network
        self.fetcher = fetcher
        self.nowMs = nowMs
    }

    /// One authority's vote for `slot`.
    public struct Vote: Sendable, Equatable {
        public var source: String
        public var slot: UInt64
        public var root: String
        public var finalizedEpoch: UInt64
    }

    private func metadata(_ source: String, _ path: String) async throws -> [String: Any] {
        guard let url = URL(string: source + path) else { throw MyotisCheckpointError.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        let bytes = try await fetcher.fetch(request, limit: Self.maxMetadataBytes)
        guard let object = try? JSONSerialization.jsonObject(with: bytes),
              let dictionary = object as? [String: Any]
        else { throw MyotisCheckpointError.unavailable }
        return dictionary
    }

    /// Desktop `checkpointVote`. Two GETs in parallel: the block root at
    /// `slot`, and the head finality checkpoints. The root only counts
    /// once finality covers the slot; when the finalized root differs
    /// the authority's finalized-slot history must list exactly this
    /// slot with exactly this root.
    public func vote(source: String, slot: UInt64) async throws -> Vote {
        async let blockTask = metadata(source, "/eth/v1/beacon/blocks/\(slot)/root")
        async let finalityTask = metadata(source, "/eth/v1/beacon/states/head/finality_checkpoints")
        let block = try await blockTask
        let finality = try await finalityTask
        for body in [block, finality] {
            if let flag = body["execution_optimistic"] {
                guard let optimistic = flag as? Bool else { throw MyotisCheckpointError.unavailable }
                if optimistic { throw MyotisCheckpointError.quorumConflict }
            }
        }
        let blockData = block["data"] as? [String: Any]
        let finalityData = finality["data"] as? [String: Any]
        let finalized = finalityData?["finalized"] as? [String: Any]
        guard let root = MyotisHex.root(blockData?["root"] as? String) else {
            throw MyotisCheckpointError.unavailable
        }
        guard let epoch = MyotisHex.uint(finalized?["epoch"]) else { throw MyotisCheckpointError.unavailable }
        guard let finalizedRoot = MyotisHex.root(finalized?["root"] as? String) else {
            throw MyotisCheckpointError.unavailable
        }
        let (epochSlot, overflow) = epoch.multipliedReportingOverflow(by: network.slotsPerEpoch)
        let wallSlot = network.wallSlot(nowMs: nowMs())
        if overflow || Int64(clamping: epochSlot) > wallSlot { throw MyotisCheckpointError.clock }
        if epochSlot < slot { throw MyotisCheckpointError.race }
        if finalizedRoot != root {
            if epoch == network.epochCeil(slot) { throw MyotisCheckpointError.quorumConflict }
            let history = try await metadata(source, "/checkpointz/v1/beacon/slots")
            guard let slots = (history["data"] as? [String: Any])?["slots"] as? [Any], slots.count <= 256 else {
                throw MyotisCheckpointError.unavailable
            }
            var entries: [[String: Any]] = []
            for entry in slots {
                guard let entry = entry as? [String: Any] else { continue }
                guard let entrySlot = MyotisHex.uint(entry["slot"]) else { throw MyotisCheckpointError.unavailable }
                if entrySlot == slot { entries.append(entry) }
            }
            guard !entries.isEmpty else { throw MyotisCheckpointError.race }
            guard entries.count == 1, let historyRoot = MyotisHex.root(entries[0]["block_root"] as? String) else {
                throw MyotisCheckpointError.quorumConflict
            }
            if historyRoot != root { throw MyotisCheckpointError.quorumConflict }
        }
        return Vote(source: source, slot: slot, root: root, finalizedEpoch: network.epochCeil(slot))
    }

    /// Desktop `checkpointQuorum`. Seats are filled in stable candidate
    /// order; a definitive answer (a vote, or any non-availability
    /// failure) occupies its seat, only `unavailable`/`race` free it for
    /// the next reserve. First root group reaching `threshold` wins.
    public func quorum(slot: UInt64) async throws -> MyotisCheckpointObservation {
        var results: [Result<Vote, MyotisCheckpointError>] = []
        var next = 0
        var occupied = 0
        let sources = network.sources
        while next < sources.count, occupied < network.participants {
            let candidates = Array(sources[next ..< min(sources.count, next + network.participants - occupied)])
            next += candidates.count
            let batch: [Result<Vote, MyotisCheckpointError>] = await withTaskGroup(
                of: (Int, Result<Vote, MyotisCheckpointError>).self
            ) { group in
                for (index, source) in candidates.enumerated() {
                    group.addTask {
                        do {
                            return (index, .success(try await self.vote(source: source, slot: slot)))
                        } catch {
                            return (index, .failure(MyotisCheckpointError.wrap(error)))
                        }
                    }
                }
                var ordered = [Result<Vote, MyotisCheckpointError>?](repeating: nil, count: candidates.count)
                for await (index, result) in group { ordered[index] = result }
                return ordered.map { $0 ?? .failure(.unavailable) }
            }
            results.append(contentsOf: batch)
            occupied += batch.filter { result in
                switch result {
                case .success: return true
                case .failure(let code): return code != .unavailable && code != .race
                }
            }.count
            var groups: [String: [Vote]] = [:]
            var order: [String] = []
            for case .success(let vote) in results {
                if groups[vote.root] == nil { order.append(vote.root) }
                groups[vote.root, default: []].append(vote)
            }
            for root in order {
                if let group = groups[root], group.count >= network.threshold {
                    return MyotisCheckpointObservation(
                        slot: slot, root: root, finalizedEpoch: group[0].finalizedEpoch,
                        sources: group.map(\.source)
                    )
                }
            }
        }
        let roots = Set(results.compactMap { if case .success(let vote) = $0 { vote.root } else { nil } })
        let failures = results.compactMap { if case .failure(let code) = $0 { code } else { nil } }
        if roots.count > 1 || failures.contains(.quorumConflict) { throw MyotisCheckpointError.quorumConflict }
        if !results.isEmpty, failures.count == results.count, failures.allSatisfy({ $0 == .clock }) {
            throw MyotisCheckpointError.clock
        }
        throw MyotisCheckpointError.quorumUnavailable
    }
}

/// The host-side corroboration step (desktop: a disposable Colibri WASM
/// verifier). MyotisKit does not depend on Colibri; the app injects an
/// implementation. Contract:
///
/// 1. Verify `proof` (a committee-history proof for the latest block,
///    fetched by the acquirer from the network's prover) with a FRESH
///    verifier state — never a cached committee.
/// 2. Every checkpoint root the verifier wants to fetch MUST be answered
///    through `trust(slot)` — the interception boundary — and nothing
///    else may be fetched. `trust` returns the quorum-endorsed root for
///    that slot or throws a `MyotisCheckpointError`.
/// 3. Return the observations consumed, in order. Throw `.stale` when
///    the verifier reports the latest proof too old, `.mismatch` on any
///    other verification failure; rethrow the `trust` error unchanged.
public protocol MyotisCheckpointCorroborator: Sendable {
    /// The encoded client version (`major * 65536 + minor * 256 + patch`)
    /// of the installed verifier, advertised in the prover request so the
    /// prover returns a proof format this verifier can decode.
    var proofVersion: Int { get }

    func corroborate(
        network: MyotisCheckpointNetwork,
        proof: Data,
        trust: @escaping @Sendable (UInt64) async throws -> MyotisCheckpointObservation
    ) async throws -> [MyotisCheckpointObservation]
}

/// Bookkeeping shared between the acquirer and the corroborator's
/// interception callback: memoized quorum lookups per slot, the
/// observations handed out, the request cap and the first transport
/// failure (which must win over a verifier error so an outage is never
/// presented as conflicting proof).
actor MyotisTrustLedger {
    private let quorum: MyotisCheckpointQuorum
    private var lookups: [UInt64: Task<MyotisCheckpointObservation, Error>] = [:]
    private(set) var observations: [MyotisCheckpointObservation] = []
    private(set) var transportError: MyotisCheckpointError?
    private var requestCount = 0
    private let maxRequests: Int

    init(quorum: MyotisCheckpointQuorum, maxRequests: Int) {
        self.quorum = quorum
        self.maxRequests = maxRequests
    }

    func trust(slot: UInt64) async throws -> MyotisCheckpointObservation {
        do {
            requestCount += 1
            guard requestCount <= maxRequests else { throw MyotisCheckpointError.unavailable }
            let lookup: Task<MyotisCheckpointObservation, Error>
            if let existing = lookups[slot] {
                lookup = existing
            } else {
                let quorum = self.quorum
                lookup = Task { try await quorum.quorum(slot: slot) }
                lookups[slot] = lookup
            }
            let observation = try await lookup.value
            observations.append(observation)
            return observation
        } catch {
            let wrapped = MyotisCheckpointError.wrap(error)
            if transportError == nil { transportError = wrapped }
            throw wrapped
        }
    }

    func cancelAll() {
        for lookup in lookups.values { lookup.cancel() }
    }
}

/// Desktop `verifyCheckpoint` + `acquireCheckpoint`: fetch the prover's
/// committee-history proof, let the corroborator verify it against the
/// quorum through the interception boundary, then bind the result into
/// a validated `MyotisCheckpointRecord`. Whole attempt bounded by
/// `deadlineSeconds`; cancellation propagates.
public struct MyotisCheckpointAcquirer: Sendable {
    public static let deadlineSeconds: UInt64 = 90
    public static let maxProofBytes = 4 * 1024 * 1024
    public static let maxTrustRequests = 8

    public let fetcher: MyotisCheckpointFetcher
    public let corroborator: MyotisCheckpointCorroborator
    public let nowMs: @Sendable () -> Int64

    public init(
        fetcher: MyotisCheckpointFetcher,
        corroborator: MyotisCheckpointCorroborator,
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.fetcher = fetcher
        self.corroborator = corroborator
        self.nowMs = nowMs
    }

    public func acquire(chainId: UInt64) async throws -> MyotisCheckpointRecord {
        let network = try MyotisCheckpointNetwork.forChain(chainId)
        return try await withThrowingTaskGroup(of: MyotisCheckpointRecord.self) { group in
            group.addTask { try await self.verify(network: network) }
            group.addTask {
                try await Task.sleep(nanoseconds: Self.deadlineSeconds * 1_000_000_000)
                throw MyotisCheckpointError.unavailable
            }
            defer { group.cancelAll() }
            do {
                guard let first = try await group.next() else { throw MyotisCheckpointError.unavailable }
                return first
            } catch {
                throw MyotisCheckpointError.wrap(error)
            }
        }
    }

    private func verify(network: MyotisCheckpointNetwork) async throws -> MyotisCheckpointRecord {
        let quorum = MyotisCheckpointQuorum(network: network, fetcher: fetcher, nowMs: nowMs)
        let ledger = MyotisTrustLedger(quorum: quorum, maxRequests: Self.maxTrustRequests)
        defer { Task { await ledger.cancelAll() } }

        guard let proverURL = URL(string: network.prover) else { throw MyotisCheckpointError.unavailable }
        var request = URLRequest(url: proverURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        guard corroborator.proofVersion > 0 else { throw MyotisCheckpointError.incompatible }
        let body: [String: Any] = [
            "method": "eth_getBlockByNumber",
            "params": ["latest", false],
            "version": corroborator.proofVersion,
            "zk_proof": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let proof = try await fetcher.fetch(request, limit: Self.maxProofBytes)
        guard !proof.isEmpty else { throw MyotisCheckpointError.unavailable }
        try Task.checkCancellation()

        let observations: [MyotisCheckpointObservation]
        do {
            observations = try await corroborator.corroborate(network: network, proof: proof) { slot in
                try await ledger.trust(slot: slot)
            }
        } catch {
            if let transport = await ledger.transportError { throw transport }
            throw MyotisCheckpointError.wrap(error)
        }
        if let transport = await ledger.transportError { throw transport }
        // A verifier that never asked for a checkpoint root bypassed the
        // independently selected authority — unsupported, not success.
        guard !observations.isEmpty else { throw MyotisCheckpointError.incompatible }
        // iOS binding caveat: the Colibri Swift package exposes no proof
        // decoder, so the checkpoint header's slot/root cannot be
        // re-hashed here as desktop does. The binding instead relies on
        // the verifier having Merkle-verified its committee against
        // exactly the root we answered for exactly the slot it asked —
        // so there must be ONE such (slot, root), or the binding is
        // ambiguous and we fail closed. The engine then re-verifies the
        // header it bootstraps from and the node cross-checks the
        // finalized root against this record (`canFinishRecovery`).
        let distinct = Set(observations.map { "\($0.slot):\($0.root)" })
        guard distinct.count == 1, let observation = observations.last, observation.slot > 0 else {
            throw MyotisCheckpointError.incompatible
        }
        let now = nowMs()
        let slotTime = network.slotTimeMs(observation.slot)
        if slotTime > now { throw MyotisCheckpointError.clock }
        if now - slotTime > MyotisCheckpointRecord.maxAgeMs { throw MyotisCheckpointError.stale }
        let record = MyotisCheckpointRecord(
            chainId: network.chainId, network: network.network, root: observation.root,
            slot: observation.slot, verifiedAt: now, sources: observation.sources,
            finalizedEpoch: observation.finalizedEpoch
        )
        return try record.validated(chainId: network.chainId, nowMs: now, fresh: true)
    }
}
