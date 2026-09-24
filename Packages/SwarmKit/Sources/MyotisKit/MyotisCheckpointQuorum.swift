import Foundation

/// Stale-anchor recovery, part 2: the external checkpoint quorum. Port
/// of desktop `checkpoint-verifier-worker.js` `checkpointVote` /
/// `checkpointQuorum` / `fetchBytes` (PR #353, PR #416) — same
/// endpoints, same evidence rules, same replacement rule, same error
/// classes, same bounded per-source diagnostics.
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
            guard let http = response as? HTTPURLResponse else {
                throw MyotisCheckpointTransportError(.transport)
            }
            guard http.statusCode == 200 else {
                throw MyotisCheckpointTransportError(.http, httpStatus: http.statusCode)
            }
            if http.expectedContentLength >= 0, http.expectedContentLength > Int64(limit) {
                throw MyotisCheckpointTransportError(.bodyLimit)
            }
            var data = Data()
            data.reserveCapacity(min(limit, Int(max(0, http.expectedContentLength))))
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { throw MyotisCheckpointTransportError(.bodyLimit) }
            }
            return data
        } catch let error as MyotisCheckpointTransportError {
            throw error
        } catch let error as MyotisCheckpointError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw MyotisCheckpointTransportError(.timeout)
        } catch {
            throw MyotisCheckpointTransportError(.transport)
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
    /// Per-source outcome sink (log lines). Observation only: a throwing
    /// or slow sink cannot affect a vote. At most `maxDiagnostics` per
    /// quorum client.
    public let onDiagnostic: (@Sendable (MyotisCheckpointSourceDiagnostic) -> Void)?
    public static let maxDiagnostics = 64

    public init(
        network: MyotisCheckpointNetwork,
        fetcher: MyotisCheckpointFetcher,
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        onDiagnostic: (@Sendable (MyotisCheckpointSourceDiagnostic) -> Void)? = nil
    ) {
        self.network = network
        self.fetcher = fetcher
        self.nowMs = nowMs
        self.onDiagnostic = onDiagnostic
    }

    /// One authority's vote for `slot`.
    public struct Vote: Sendable, Equatable {
        public var source: String
        public var slot: UInt64
        public var root: String
        public var finalizedEpoch: UInt64
    }

    private func metadata(
        _ source: String, _ path: String, stage: MyotisCheckpointStagedError.Stage
    ) async throws -> [String: Any] {
        do {
            guard let url = URL(string: source + path) else { throw MyotisCheckpointTransportError(.transport) }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "accept")
            let bytes = try await fetcher.fetch(request, limit: Self.maxMetadataBytes)
            guard let object = try? JSONSerialization.jsonObject(with: bytes),
                  let dictionary = object as? [String: Any]
            else { throw MyotisCheckpointTransportError(.invalidJSON) }
            return dictionary
        } catch {
            throw MyotisCheckpointStagedError(stage: stage, underlying: error)
        }
    }

    /// Desktop `checkpointVote`. Two GETs in parallel: the block root at
    /// `slot`, and the head finality checkpoints. The root only counts
    /// once finality covers the slot; when the finalized root differs
    /// the authority's finalized-slot history must list exactly this
    /// slot with exactly this root.
    public func vote(source: String, slot: UInt64) async throws -> Vote {
        do {
            return try await voteDetailed(source: source, slot: slot)
        } catch {
            throw MyotisCheckpointError.wrap(error)
        }
    }

    /// `vote` with the failing stage attached (`MyotisCheckpointStagedError`)
    /// for the diagnostics; the verdict is the same.
    func voteDetailed(source: String, slot: UInt64) async throws -> Vote {
        async let blockTask = metadata(source, "/eth/v1/beacon/blocks/\(slot)/root", stage: .blockRoot)
        async let finalityTask = metadata(source, "/eth/v1/beacon/states/head/finality_checkpoints", stage: .finality)
        let block = try await blockTask
        let finality = try await finalityTask
        for body in [block, finality] {
            if let flag = body["execution_optimistic"] {
                guard let optimistic = flag as? Bool else { throw MyotisCheckpointError.unavailable }
                if optimistic { throw MyotisCheckpointError.quorumConflict }
            }
        }
        // The requested BLOCK's own finality flag (Beacon API primitive).
        // A head STATE can be unfinalized while its reported finalized
        // checkpoint is valid — the state response's top-level flag is
        // never read as evidence for this vote.
        var blockFinalized: Bool?
        if let flag = block["finalized"] {
            guard let value = flag as? Bool else { throw MyotisCheckpointError.unavailable }
            blockFinalized = value
        }
        if blockFinalized == false { throw MyotisCheckpointError.race }
        let blockEndorsed = blockFinalized == true && block["execution_optimistic"] as? Bool == false
        // A standard Beacon API authority has no finalized-slot history:
        // without the explicit endorsement on the block it cannot vote.
        if network.beaconSources.contains(source), !blockEndorsed { throw MyotisCheckpointError.unavailable }
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
            // The block is older than the authority's current finalized
            // checkpoint. Its explicit `finalized: true` endorses finalized
            // history — no Checkpointz history scan needed (PublicNode
            // has none). Otherwise the finalized-slot history must list
            // exactly this slot with exactly this root.
            if blockEndorsed {
                return Vote(source: source, slot: slot, root: root, finalizedEpoch: network.epochCeil(slot))
            }
            let history = try await metadata(source, "/checkpointz/v1/beacon/slots", stage: .history)
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
                        let started = self.nowMs()
                        var failure: Error?
                        defer {
                            // Diagnostics cannot affect a vote: built from bounded
                            // fields only, delivered best-effort.
                            if let sink = self.onDiagnostic,
                               let diagnostic = MyotisCheckpointSourceDiagnostic(
                                   source: source, network: self.network, slot: slot,
                                   elapsedMs: Int(clamping: self.nowMs() - started), error: failure
                               )
                            {
                                sink(diagnostic)
                            }
                        }
                        do {
                            return (index, .success(try await self.voteDetailed(source: source, slot: slot)))
                        } catch {
                            failure = error
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
    /// Per-source outcome sink, bounded to `MyotisCheckpointQuorum.maxDiagnostics`
    /// per acquisition; never affects the verdict.
    public let onDiagnostic: (@Sendable (MyotisCheckpointSourceDiagnostic) -> Void)?

    public init(
        fetcher: MyotisCheckpointFetcher,
        corroborator: MyotisCheckpointCorroborator,
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        onDiagnostic: (@Sendable (MyotisCheckpointSourceDiagnostic) -> Void)? = nil
    ) {
        self.fetcher = fetcher
        self.corroborator = corroborator
        self.nowMs = nowMs
        self.onDiagnostic = onDiagnostic
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
        let budget = DiagnosticBudget(limit: MyotisCheckpointQuorum.maxDiagnostics)
        let sink = onDiagnostic
        let quorum = MyotisCheckpointQuorum(network: network, fetcher: fetcher, nowMs: nowMs) { diagnostic in
            guard let sink, budget.take() else { return }
            sink(diagnostic)
        }
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

/// Counts diagnostics handed out per acquisition (desktop caps at 64).
final class DiagnosticBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    init(limit: Int) { remaining = limit }
    func take() -> Bool {
        lock.withLock {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }
}
