import BigInt
import Foundation
import OSLog
import web3
import ENSNormalize

private let log = Logger(subsystem: "com.browser.Freedom", category: "ENSResolver")

private extension QuorumWave.TrustTier {
    var level: ENSTrustLevel {
        switch self {
        case .verified: .verified
        case .unverified: .unverified
        }
    }
}

@MainActor
@Observable
final class ENSResolver {
    static let universalResolverAddress = UniversalResolverABI.address

    enum ConsensusResult: @unchecked Sendable {
        case data(resolvedData: Data, resolverAddress: EthereumAddress, trust: ENSTrust)
        case notFound(reason: ENSNotFoundReason, trust: ENSTrust)
        case conflict(groups: [ENSConflictGroup], trust: ENSTrust)

        var trustLevel: ENSTrustLevel {
            switch self {
            case .data(_, _, let trust), .notFound(_, let trust), .conflict(_, let trust):
                return trust.level
            }
        }
    }

    enum ConsensusError: Error {
        case noProviders
        case allErrored
    }

    private static let contenthashSelector = UniversalResolverABI.contenthashSelector

    private let pool: EthereumRPCPool
    private let settings: SettingsStore
    private let anchor: AnchorCorroboration
    private let legRunner: QuorumWave.LegRunner
    private let reverseTransport: ReverseTransport
    private let reverseCCIPHTTP: CCIPResolver.HTTPClient
    private let clock: () -> Date
    /// Cryptographic ENS path. Nil in unit tests that don't exercise the
    /// Colibri branch — `consensusResolve` then skips Colibri regardless
    /// of `settings.ensResolutionMethod`.
    private let colibri: ColibriENSClient?
    /// Fully-P2P verified path (embedded Myotis light client). Nil in
    /// unit tests that don't exercise it. Unlike Colibri this tier is not
    /// method-picker-gated: it runs first whenever the client reports
    /// available, falling through unconditionally otherwise — the picker
    /// chooses what it falls back TO.
    private let myotis: MyotisENSClient?

    typealias ReverseTransport = @Sendable (URL, Data, TimeInterval) async throws -> Data
    nonisolated static let defaultReverseTransport: ReverseTransport = { url, body, timeout in
        try await RPCSession.postBytes(url: url, body: body, timeout: timeout)
    }

    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<CachedOutcome, Never>] = [:]
    private var addressCache: [String: AddressCacheEntry] = [:]
    private var addressInFlight: [String: Task<Result<EthereumAddress, ENSResolutionError>, Never>] = [:]
    private var reverseCache: [String: ReverseCacheEntry] = [:]

    init(
        pool: EthereumRPCPool,
        settings: SettingsStore,
        anchor: AnchorCorroboration? = nil,
        legRunner: @escaping QuorumWave.LegRunner = QuorumWave.defaultLegRunner,
        reverseTransport: @escaping ReverseTransport = ENSResolver.defaultReverseTransport,
        reverseCCIPHTTP: @escaping CCIPResolver.HTTPClient = CCIPResolver.defaultHTTP,
        clock: @escaping () -> Date = Date.init,
        colibri: ColibriENSClient? = nil,
        myotis: MyotisENSClient? = nil
    ) {
        self.pool = pool
        self.settings = settings
        self.anchor = anchor ?? AnchorCorroboration(pool: pool, settings: settings)
        self.legRunner = legRunner
        self.reverseTransport = reverseTransport
        self.reverseCCIPHTTP = reverseCCIPHTTP
        self.clock = clock
        self.colibri = colibri
        self.myotis = myotis
    }

    // MARK: - Public entry

    /// Clears the name cache, cancels in-flight resolutions, and resets
    /// the anchor cache + pool quarantine. Call after a settings edit so
    /// stale verifications don't linger against the new configuration.
    func invalidate() {
        cache.removeAll()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        anchor.invalidate()
        pool.invalidate()
        colibri?.invalidate()
    }

    /// Clears the result caches only (content, address, reverse), leaving
    /// pool quarantine / anchor / client state intact. Called when the
    /// Myotis node's availability flips in either direction, so takeover
    /// (upgrade lower-tier answers to P2P-verified) and failover (stop
    /// serving results the now-gone tier minted) happen immediately
    /// instead of waiting out cached TTLs. Desktop parity.
    func sweepResultCaches() {
        myotisTimeoutCount = 0
        myotisCooldownUntil = .distantPast
        cache.removeAll()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        addressCache.removeAll()
        for task in addressInFlight.values { task.cancel() }
        addressInFlight.removeAll()
        reverseCache.removeAll()
    }

    // MARK: - Myotis takeover

    /// Cache life of an answer a LOWER tier minted while the Myotis node
    /// reported itself available but its read fell through. Right after
    /// SYNCED the engine's snap pool can lag the verified tip for a
    /// minute or two ("peer returned 0 headers") and every P2P read
    /// fails; pinning the Colibri/quorum answer for the verified 15 min
    /// would keep showing the lower tier long after the node can serve.
    /// Observed on the simulator: attempts 1–3 fell through, 4+ were
    /// P2P-verified.
    static let takeoverTTL: TimeInterval = 60

    /// True after a Myotis read fell through while the node was
    /// available; the first P2P-verified answer afterwards drops the
    /// result caches so other names cached from lower tiers in the
    /// meantime get their P2P attempt immediately.
    private var myotisFellThrough = false

    /// Optional cap on how long a lookup waits for Myotis when a later
    /// method is enabled; nil means the configured timeout (desktop
    /// parity). Measured on the simulator (2026-09-20): a serving
    /// engine answers a name in 3.7–19 s on this build because it asks
    /// peers one after another and one hung peer costs its 15 s request
    /// timeout, so a tight cap would starve Myotis rather than protect
    /// the user. A late answer is not wasted either — see
    /// `noteLateMyotisAnswer`. Tests shorten it.
    var myotisDeadline: TimeInterval?
    /// Escalating skip after Myotis timed out on a lookup, so the next
    /// navigations do not each pay the budget again while the engine
    /// catches up. Cleared when Myotis serves again or its availability
    /// flips. Same schedule as the chain-data router's route cooldowns.
    private var myotisTimeoutCount = 0
    private var myotisCooldownUntil: Date = .distantPast

    private var myotisCoolingDown: Bool { clock() < myotisCooldownUntil }

    private func noteMyotisTimeout() {
        myotisTimeoutCount += 1
        let cooldown = AdaptiveRouting.timeoutCooldowns[min(myotisTimeoutCount, AdaptiveRouting.timeoutCooldowns.count) - 1]
        myotisCooldownUntil = clock().addingTimeInterval(cooldown)
        log.info("[ens] myotis timed out — skipping it for \(Int(cooldown))s")
    }

    private func noteMyotisFallthrough() {
        myotisFellThrough = true
    }

    /// A Myotis read that finished after the lookup had already moved
    /// on to a later method still tells us the engine serves: drop the
    /// lower-tier results cached meanwhile so the next lookups go back
    /// to Myotis, and forget the timeout escalation.
    private func noteLateMyotisAnswer() {
        log.info("[ens] myotis answered after the budget — adopting it for the next lookups")
        myotisFellThrough = true
        noteMyotisServed()
    }

    /// Run a Myotis read with a bounded wait. The read itself keeps
    /// running past the deadline (engine calls are not cancellable) and
    /// its outcome is observed: a late success is adopted via
    /// `noteLateMyotisAnswer`.
    private func boundedMyotis<T: Sendable>(
        wait: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let work = Task { try await operation() }
        do {
            return try await withSourceDeadline(wait, source: .myotis) { try await work.value }
        } catch is ChainSourceDeadline {
            Task { @MainActor [weak self] in
                guard (try? await work.value) != nil else { return }
                self?.noteLateMyotisAnswer()
            }
            throw ChainSourceDeadline(source: .myotis, seconds: wait)
        }
    }

    private func noteMyotisServed() {
        myotisTimeoutCount = 0
        myotisCooldownUntil = .distantPast
        guard myotisFellThrough else { return }
        myotisFellThrough = false
        // Drop cached results only — in-flight resolutions (including
        // the one calling this) finish and cache normally.
        cache.removeAll()
        addressCache.removeAll()
        reverseCache.removeAll()
        log.info("[ens] myotis serving again — dropped lower-tier cached results for takeover")
    }

    /// Resolve an ENS name to a navigable content URL. Normalizes via
    /// ENSIP-15 (adraffy/ENSNormalize), computes the namehash, runs the
    /// consensus pipeline, decodes the contenthash. Concurrent calls for
    /// the same normalized name share one Task; successful results are
    /// cached with trust-tier-specific TTLs matching desktop (verified
    /// 15min, unverified 60s, conflict 10s negative cache).
    func resolveContent(_ name: String) async throws -> ENSResolvedContent {
        let normalized: String
        do {
            normalized = try name.ensNormalized()
        } catch {
            throw ENSResolutionError.invalidName
        }

        if let cached = cache[normalized], clock() < cached.expiresAt {
            return try cached.outcome.unwrap()
        }
        if let task = inFlight[normalized] {
            return try await task.value.unwrap()
        }

        let task = Task { @MainActor in
            let outcome = await self.doResolveContent(normalized)
            // If invalidate() cancelled us between task launch and this
            // point, skip the cache write — the cache was just cleared
            // and we'd re-pollute it with stale data.
            guard !Task.isCancelled else {
                self.inFlight.removeValue(forKey: normalized)
                return outcome
            }
            self.storeAndClear(normalized: normalized, outcome: outcome)
            return outcome
        }
        inFlight[normalized] = task
        return try await task.value.unwrap()
    }

    private func storeAndClear(normalized: String, outcome: CachedOutcome) {
        if outcome.isCacheable {
            cache[normalized] = CacheEntry(
                outcome: outcome,
                expiresAt: clock().addingTimeInterval(effectiveTTL(outcome))
            )
            capCache()
        }
        inFlight.removeValue(forKey: normalized)
    }

    /// The outcome's own TTL, capped at `takeoverTTL` when a lower tier
    /// answered although Myotis was available (its read fell through).
    private func effectiveTTL(_ outcome: CachedOutcome) -> TimeInterval {
        guard let myotis, myotis.isAvailable else { return outcome.ttl }
        if case .success(let content) = outcome, content.trust.method == .myotis { return outcome.ttl }
        if case .failure(.notFound(_, let trust)) = outcome, trust.method == .myotis { return outcome.ttl }
        return min(outcome.ttl, Self.takeoverTTL)
    }

    // Desktop's policy: when over the cap, drop expired entries first;
    // if still over, fall through to arbitrary-order eviction. Bounded
    // memory during long browsing sessions with many distinct names.
    private static let maxCacheEntries = 500

    private func capCache() {
        guard cache.count > Self.maxCacheEntries else { return }
        let now = clock()
        cache = cache.filter { $0.value.expiresAt > now }
        while cache.count > Self.maxCacheEntries, let key = cache.keys.first {
            cache.removeValue(forKey: key)
        }
    }

    private func doResolveContent(_ normalized: String) async -> CachedOutcome {
        let dnsEncoded: Data
        do {
            dnsEncoded = try ENSNameEncoding.dnsEncode(normalized)
        } catch {
            return .failure(.invalidName)
        }
        let node = ENSNameEncoding.namehash(normalized)
        let callData = Self.contenthashSelector + node
        let system = NameSystem.forName(normalized)

        let consensus: ConsensusResult
        do {
            consensus = try await consensusResolve(
                dnsEncodedName: dnsEncoded, callData: callData, system: system
            )
        } catch let err as AnchorCorroboration.AnchorError {
            // Security signal — preserve distinct from plain network failure.
            // Short-TTL cached (below) to avoid re-hammering providers during
            // an active disagreement.
            switch err {
            case .hashDisagreement(let largest, let total, let threshold):
                return .failure(.anchorDisagreement(
                    largestBucketSize: largest, total: total, threshold: threshold
                ))
            }
        } catch ENSResolutionError.customRpcFailed {
            return .failure(.customRpcFailed)
        } catch {
            // allErrored / noProviders / transport. Surfaced as
            // .allProvidersErrored, which `isCacheable` treats as
            // non-cacheable so retries re-attempt once the network recovers.
            return .failure(.allProvidersErrored)
        }

        switch consensus {
        case .data(let abiEncoded, _, let trust):
            let innerBytes: Data
            do {
                innerBytes = try ContenthashDecoder.unwrapABIBytes(abiEncoded)
            } catch {
                return .failure(.unsupportedCodec(rawBytes: abiEncoded, trust: trust))
            }
            if innerBytes.isEmpty {
                return .failure(.notFound(reason: .emptyContenthash, trust: trust))
            }
            guard let (_, codec, contentRef) = ContenthashDecoder.decode(innerBytes) else {
                return .failure(.unsupportedCodec(rawBytes: innerBytes, trust: trust))
            }
            // Construct the URI from the ENS name, not from the decoded
            // content reference — `vitalik.eth` resolves to
            // `ipfs://vitalik.eth`, not `ipfs://<cid>`. The handlers
            // re-resolve on each request (cheap cache hit) and use
            // `contentRef` to route the upstream fetch. Keeping the
            // origin tied to the name means storage / cookies /
            // localStorage survive contenthash rotation by the record
            // owner, matching desktop Freedom's standard-scheme model.
            //
            // `URLComponents` over `URL(string:)` because ENSIP-15
            // normalization can produce non-ASCII hosts (emoji.eth,
            // IDN labels) — `URL(string:)` rejects those, `URLComponents`
            // handles the percent/IDN encoding.
            //
            // One exception: a DNS-imported ENS name (`example.com`)
            // whose contenthash is IPNS. `ipns://example.com` already
            // means DNSLink, so the name-host form would change meaning
            // on reload; such names load by content key instead (the tab
            // still carries the ENS trust). Suffix names (`.eth`) have no
            // DNS equivalent and keep the name-host origin.
            let nameHostIsUnambiguous = codec != .ipns
                || NameSystem.navigableSuffixes.contains(where: normalized.hasSuffix)
            var components = URLComponents()
            components.scheme = codec.scheme
            components.host = nameHostIsUnambiguous ? normalized : contentRef
            guard let uri = components.url else {
                return .failure(.unsupportedCodec(rawBytes: innerBytes, trust: trust))
            }
            return .success(ENSResolvedContent(
                name: normalized, uri: uri, contentRef: contentRef, codec: codec, trust: trust
            ))
        case .notFound(let reason, let trust):
            return .failure(.notFound(reason: reason, trust: trust))
        case .conflict(let groups, let trust):
            return .failure(.conflict(groups: groups, trust: trust))
        }
    }

    // MARK: - Cache types

    private struct CacheEntry {
        let outcome: CachedOutcome
        let expiresAt: Date
    }

    private enum CachedOutcome {
        case success(ENSResolvedContent)
        case failure(ENSResolutionError)

        func unwrap() throws -> ENSResolvedContent {
            switch self {
            case .success(let c): return c
            case .failure(let e): throw e
            }
        }

        /// `.allProvidersErrored` is a transient network failure — retries
        /// may succeed once the network recovers, so don't pin it. Every
        /// other outcome (including negative results) is cacheable per the
        /// TTL below.
        var isCacheable: Bool {
            switch self {
            case .failure(.allProvidersErrored), .failure(.customRpcFailed): return false
            default: return true
            }
        }

        /// TTL per desktop's policy — verified answers are stable across
        /// short windows, unverified or conflict states shouldn't pin for
        /// long.
        var ttl: TimeInterval {
            switch self {
            case .success(let c):
                switch c.trust.level {
                case .verified, .userConfigured: return 15 * 60
                case .unverified: return 60
                case .conflict: return 10
                }
            case .failure(.notFound(_, let trust)):
                return trust.level == .verified ? 15 * 60 : 60
            case .failure(.conflict), .failure(.anchorDisagreement):
                return 10
            case .failure:
                return 60
            }
        }
    }

    // MARK: - Consensus orchestration

    /// Drives the quorum pipeline: feasibility → anchor → wave → optional
    /// second-wave → final trust-labelled result. Matches the desktop
    /// consensusResolve outcome taxonomy one-to-one. `system` picks the
    /// call target per leg: UR resolve() for `.ens`, a direct NameNFT
    /// contract call for `.wns`/`.gns` — the consensus machinery itself
    /// is identical either way.
    func consensusResolve(
        dnsEncodedName: Data,
        callData: Data,
        system: NameSystem = .ens
    ) async throws -> ConsensusResult {
        let timeout = TimeInterval(settings.ensQuorumTimeoutMs) / 1000

        // Desktop "Resolution order": the enabled methods, top to bottom.
        // A tier's own failure (prover error, P2P warm-up, an infeasible
        // quorum, a dead custom node) falls through to the next one; a
        // deterministic answer — data, a verified negative, a conflict,
        // an anchor disagreement — ends the walk. With "prefer verified"
        // on, an unverified Direct RPC answer is held while later methods
        // try to produce a verified one.
        var unverifiedFallback: ConsensusResult?
        var lastError: Error?
        /// The user's own node failing is the actionable message when
        /// nothing else answers either — surfaced over generic failures.
        var customRPCError: Error?
        let enabled = settings.ensEnabledResolutionMethods
        for (index, method) in enabled.enumerated() {
            try Task.checkCancellation()
            do {
                let result: ConsensusResult
                switch method {
                case .myotis:
                    guard let myotis, myotis.isAvailable else { continue }
                    if myotisCoolingDown {
                        log.info("[ens] myotis skipped — cooling down after a timeout")
                        continue
                    }
                    let hasLater = index + 1 < enabled.count
                    let wait = hasLater ? min(timeout, myotisDeadline ?? timeout) : timeout
                    do {
                        result = try await boundedMyotis(wait: wait) {
                            try await self.tryMyotis(
                                dnsEncodedName: dnsEncodedName, callData: callData,
                                client: myotis, system: system
                            )
                        }
                        noteMyotisServed()
                    } catch let err as ColibriENSError {
                        log.info("[ens] myotis-fallthrough error=\(String(describing: err), privacy: .public)")
                        noteMyotisFallthrough()
                        throw err
                    } catch let err as ChainSourceDeadline {
                        noteMyotisFallthrough()
                        noteMyotisTimeout()
                        throw err
                    }
                case .colibri:
                    guard let colibri else { continue }
                    do {
                        result = try await withSourceDeadline(timeout, source: .colibri) {
                            try await self.tryColibri(
                                dnsEncodedName: dnsEncodedName, callData: callData,
                                client: colibri, system: system
                            )
                        }
                    } catch let err as ColibriENSError {
                        // Loud on purpose: a silent fall-through would hide
                        // prover health regressions and the rare attack signal.
                        log.warning("[ens] colibri-fallback error=\(String(describing: err), privacy: .public)")
                        throw err
                    }
                case .quorum:
                    result = try await resolveQuorumTier(
                        dnsEncodedName: dnsEncodedName, callData: callData,
                        timeout: timeout, system: system
                    )
                case .userConfigured:
                    result = try await resolveDirectTier(
                        dnsEncodedName: dnsEncodedName, callData: callData,
                        timeout: timeout, system: system
                    )
                case .direct:
                    continue
                }
                let isLast = index == enabled.count - 1
                if settings.ensPreferVerified, !isLast, result.trustLevel == .unverified {
                    log.info("[ens] \(method.rawValue, privacy: .public) answered unverified — holding while later methods try")
                    if unverifiedFallback == nil { unverifiedFallback = result }
                    continue
                }
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch let error where Self.isTierFallThrough(error) {
                log.info("[ens] \(method.rawValue, privacy: .public) unavailable: \(String(describing: error), privacy: .public) — next method")
                if case ENSResolutionError.customRpcFailed = error { customRPCError = error }
                lastError = error
                continue
            }
        }
        if let unverifiedFallback { return unverifiedFallback }
        throw customRPCError ?? lastError ?? ENSResolutionError.allProvidersErrored
    }

    /// A tier could not answer — the walk moves on. Everything else a
    /// tier throws is the chain's answer or a security signal.
    private static func isTierFallThrough(_ error: Error) -> Bool {
        if error is ColibriENSError || error is TierUnavailable || error is ConsensusError || error is ChainSourceDeadline { return true }
        if case ENSResolutionError.customRpcFailed = error { return true }
        if case ENSResolutionError.allProvidersErrored = error { return true }
        return false
    }

    /// "This method cannot serve right now" — the resolution order's
    /// fall-through signal, never shown to the user.
    struct TierUnavailable: Error {
        let reason: String
    }

    /// Direct RPC: the user's own endpoint when one is configured
    /// (single-source, `userConfigured`), else the first public
    /// endpoint that answers (`unverified`). Desktop's Direct method,
    /// which tries the user's endpoints before the public ones.
    private func resolveDirectTier(
        dnsEncodedName: Data,
        callData: Data,
        timeout: TimeInterval,
        system: NameSystem
    ) async throws -> ConsensusResult {
        if !settings.ensRpcUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try await resolveCustomRPC(
                dnsEncodedName: dnsEncodedName, callData: callData,
                timeout: timeout, system: system
            )
        }
        return try await resolveDirect(
            candidates: pool.availableProviders(),
            dnsEncodedName: dnsEncodedName, callData: callData,
            timeout: timeout, system: system
        )
    }

    /// RPC quorum: feasibility → anchor → wave → optional second wave →
    /// trust-labelled result. Infeasible (too few providers, K/M below
    /// the floor, no corroborated anchor) throws `TierUnavailable` so
    /// the order can move on; an anchor disagreement propagates.
    private func resolveQuorumTier(
        dnsEncodedName: Data,
        callData: Data,
        timeout: TimeInterval,
        system: NameSystem
    ) async throws -> ConsensusResult {
        let available = pool.availableProviders()
        guard !available.isEmpty else { throw TierUnavailable(reason: "no providers") }

        let desiredK = max(1, min(settings.ensQuorumK, 9))
        let desiredM = max(1, min(settings.ensQuorumM, desiredK))
        let underpowered = desiredK < AnchorCorroboration.minQuorumProviders || desiredM < 2

        if underpowered || available.count < AnchorCorroboration.minQuorumProviders {
            throw TierUnavailable(reason: "quorum infeasible")
        }

        // getPinnedBlock throws on hash disagreement (security signal),
        // returns nil on runtime infeasibility (degrade to single-source).
        let pinned = try await anchor.getPinnedBlock()

        guard let block = pinned else {
            throw TierUnavailable(reason: "quorum infeasible")
        }

        // Refresh pool — anchor step may have quarantined flakes; reusing
        // the pre-anchor snapshot would waste the wave on dead providers.
        let waveAvailable = pool.availableProviders()
        if waveAvailable.count < AnchorCorroboration.minQuorumProviders {
            throw TierUnavailable(reason: "quorum infeasible")
        }

        let effectiveK = min(desiredK, waveAvailable.count)
        let effectiveM = min(desiredM, effectiveK)
        let firstSelection = Array(waveAvailable.prefix(effectiveK))

        var wave = await QuorumWave.run(
            providers: firstSelection,
            dnsEncodedName: dnsEncodedName, callData: callData,
            blockHash: block.hash, timeout: timeout, m: effectiveM,
            enableCcipRead: settings.enableCcipRead,
            nameSystem: system,
            legRunner: legRunner
        )
        feedQuarantine(from: wave)

        // Second-wave escalation on all-errored only. Conflict and
        // unverified outcomes mean honest providers gave us answers and
        // retrying wouldn't flip the verdict. Same K≥3 floor as the first
        // wave — with 2 remaining providers, an agreeing pair would mint
        // verified trust at K=2, violating the policy that verified public
        // quorum requires ≥3 independent legs.
        if case .allErrored = wave.resolution {
            let remaining = pool.availableProviders().filter { !firstSelection.contains($0) }
            if remaining.count >= AnchorCorroboration.minQuorumProviders {
                let secondK = min(desiredK, remaining.count)
                let secondSelection = Array(remaining.prefix(secondK))
                wave = await QuorumWave.run(
                    providers: secondSelection,
                    dnsEncodedName: dnsEncodedName, callData: callData,
                    blockHash: block.hash, timeout: timeout,
                    m: min(desiredM, secondK),
                    enableCcipRead: settings.enableCcipRead,
                    nameSystem: system,
                    legRunner: legRunner
                )
                feedQuarantine(from: wave)
            }
        }

        return try buildResult(from: wave, block: block, system: system)
    }

    /// Mirror anchor corroboration's quarantine feeding for the resolve
    /// leg. Without this, providers that pass the anchor step but fail
    /// the UR.resolve call stay in the shuffle forever and burn K slots
    /// of every resolution. CCIP gateway errors aren't the RPC's fault
    /// — the RPC gave us a correct OffchainLookup revert — so those
    /// don't feed markFailure.
    private func feedQuarantine(from wave: QuorumWave.Outcome) {
        for leg in wave.legs.values {
            switch leg.kind {
            case .data, .notFound:
                pool.markSuccess(leg.url)
            case .error(let err) where !(err is CCIPResolver.CCIPError):
                pool.markFailure(leg.url)
            case .error:
                break
            }
        }
    }

    private func tryColibri(
        dnsEncodedName: Data,
        callData: Data,
        client: ColibriENSClient,
        system: NameSystem = .ens
    ) async throws -> ConsensusResult {
        // Colibri pins to head − 1 by construction (sync committee
        // signatures for block N live in block N+1), so we don't have a
        // separate anchor step / pinned block to report. ENSBlock is a
        // required field on the trust object; surface a zero placeholder
        // and the trust popover knows to render "verifier-pinned" instead
        // of a block number for `.colibri` results.
        let placeholderBlock = ENSBlock(number: 0, hash: "")
        let trust = buildColibriTrust(client: client, block: placeholderBlock, system: system)
        // NameNFT systems: one proven eth_call straight to the registry
        // contract. Reverts deliberately propagate as `ColibriENSError`
        // so the caller's quorum fallback handles them — the NameNFT
        // contracts have no UR error vocabulary to decode here (desktop
        // parity: a nameNftResolverCall throw falls through to quorum).
        if let contract = system.contractAddress {
            let (data, resolver) = try await client.nameNftCall(
                contract: contract, callData: callData
            )
            return .data(resolvedData: data, resolverAddress: resolver, trust: trust)
        }
        do {
            let (data, resolver) = try await client.universalResolverCall(
                dnsEncodedName: dnsEncodedName, callData: callData
            )
            return .data(resolvedData: data, resolverAddress: resolver, trust: trust)
        } catch ColibriENSError.revert(let revertHex) {
            switch Self.classifyColibriRevert(revertHex) {
            case .offchainLookup:
                // CCIP-gated record. Drive the gateway hop here and
                // re-execute the callback through the same verifier, so
                // the answer keeps Colibri trust (desktop PR #352).
                guard settings.enableCcipRead else {
                    return .notFound(reason: .ccipDisabled, trust: trust)
                }
                let hex = try await provenCCIP(revertHex: revertHex) { to, dataHex in
                    try await client.ccipCallback(to: to, dataHex: dataHex)
                }
                let (data, resolver) = try UniversalResolverABI.decodeResolveResponse(hex)
                return .data(resolvedData: data, resolverAddress: resolver, trust: trust)
            case .dataless:
                // Desktop-parity hardening (freedom-browser #116): a revert
                // carrying no return data is ambiguous — a degraded prover
                // hop can surface that shape — so it must not mint a
                // verified "no contenthash". Rethrow as transient so the
                // quorum fallback re-probes instead.
                throw ColibriENSError.proofFailed(
                    message: "verified revert without return data — falling back to quorum"
                )
            case .resolverNotFound:
                // The UR proved no resolver is registered — desktop's
                // NO_RESOLVER bucket.
                return .notFound(reason: .noResolver, trust: trust)
            case .executionError:
                // A proved resolver failure is not proof of an absent
                // record; let the next configured method try.
                throw ColibriENSError.proofFailed(
                    message: "resolver execution error \(CCIPResolver.selectorOf(revertHex) ?? "") — falling back"
                )
            }
        }
    }

    /// Mirror of `tryColibri` for the embedded P2P tier. Same revert
    /// classification (`classifyColibriRevert` — the shapes are chain
    /// facts, not prover artifacts), different trust label: `.myotis`
    /// results were verified end-to-end on this device against beacon
    /// finality, with no remote prover trusted for liveness or data.
    private func tryMyotis(
        dnsEncodedName: Data,
        callData: Data,
        client: MyotisENSClient,
        system: NameSystem = .ens
    ) async throws -> ConsensusResult {
        let trust = buildMyotisTrust(client: client, system: system)
        if let contract = system.contractAddress {
            let (data, resolver) = try await client.nameNftCall(
                contract: contract, callData: callData
            )
            return .data(resolvedData: data, resolverAddress: resolver, trust: trust)
        }
        do {
            let (data, resolver) = try await client.universalResolverCall(
                dnsEncodedName: dnsEncodedName, callData: callData
            )
            return .data(resolvedData: data, resolverAddress: resolver, trust: trust)
        } catch ColibriENSError.revert(let revertHex) {
            switch Self.classifyColibriRevert(revertHex) {
            case .offchainLookup:
                // CCIP-gated record: gateway hop + callback re-executed
                // in the engine's own EVM, so the result stays P2P-verified.
                guard settings.enableCcipRead else {
                    return .notFound(reason: .ccipDisabled, trust: trust)
                }
                let hex = try await provenCCIP(revertHex: revertHex) { to, dataHex in
                    try await client.ccipCallback(to: to, dataHex: dataHex)
                }
                let (data, resolver) = try UniversalResolverABI.decodeResolveResponse(hex)
                return .data(resolvedData: data, resolverAddress: resolver, trust: trust)
            case .dataless:
                // Ambiguous shape; don't mint a verified negative.
                throw ColibriENSError.proofFailed(
                    message: "verified revert without return data — falling through"
                )
            case .resolverNotFound:
                return .notFound(reason: .noResolver, trust: trust)
            case .executionError:
                throw ColibriENSError.proofFailed(
                    message: "resolver execution error \(CCIPResolver.selectorOf(revertHex) ?? "") — falling through"
                )
            }
        }
    }

    /// Whole-pass budget for a proven-tier CCIP drive: up to
    /// `CCIPResolver.maxRedirects` gateway rounds at
    /// `CCIPResolver.gatewayTimeout` each would otherwise let a slow
    /// gateway chain hold a resolution for a minute.
    static let provenCCIPBudget: TimeInterval = 30

    /// EIP-3668 on a proven tier: gateway hop(s) via `CCIPResolver`,
    /// with every callback `eth_call` re-executed through `call` — the
    /// same verifier that produced the revert — so gateway data is only
    /// ever accepted after the resolver contract validated it under
    /// proof. The sender must be the Universal Resolver (the contract we
    /// called). Every failure maps to `ColibriENSError.proofFailed`: a
    /// gateway outage or a callback revert is not a verified negative,
    /// so the tier falls through instead of caching "no record".
    private func provenCCIP(
        revertHex: String,
        call: @escaping CCIPResolver.EthCallExecutor
    ) async throws -> String {
        guard let revertBytes = revertHex.web3.hexData else {
            throw ColibriENSError.unexpectedResponse(revertHex)
        }
        let http = reverseCCIPHTTP
        do {
            return try await RPCSession.withTimeout(seconds: Self.provenCCIPBudget) {
                try await CCIPResolver.resolve(
                    revertData: revertBytes,
                    sender: Self.universalResolverAddress.asString(),
                    ethCall: call,
                    http: http,
                    timeout: CCIPResolver.gatewayTimeout
                )
            }
        } catch let err as CCIPResolver.CCIPError {
            log.warning("[ens] proven ccip failed: \(String(describing: err), privacy: .public)")
            throw ColibriENSError.proofFailed(message: "ccip: \(err)")
        } catch RPCError.executionRevert(let data) {
            log.warning("[ens] proven ccip callback reverted: \(data ?? "", privacy: .public)")
            throw ColibriENSError.proofFailed(message: "ccip callback reverted")
        } catch let err as ColibriENSError {
            throw err
        } catch {
            throw ColibriENSError.proofFailed(message: "ccip: \(error)")
        }
    }

    /// How a verified revert from a proven tier should be handled. Pure
    /// so the decision table is unit-testable without a live prover.
    enum ColibriRevertClass: Equatable {
        /// EIP-3668: the record lives behind a gateway.
        case offchainLookup
        /// No return data — a degraded prover hop can surface this shape.
        case dataless
        /// The UR's own "no resolver" errors: a verified negative.
        case resolverNotFound
        /// Any other revert. The resolver *ran and failed* (a DNSSEC
        /// `SignatureNotValidYet`, an unsupported profile, a custom
        /// error) — proof that execution failed, not proof that the
        /// record is absent. Desktop PR #352: let the next method try.
        case executionError
    }

    static func classifyColibriRevert(_ revertHex: String) -> ColibriRevertClass {
        let selector = CCIPResolver.selectorOf(revertHex)
        if selector == CCIPResolver.offchainLookupSelector {
            return .offchainLookup
        }
        if let selector, UniversalResolverABI.resolverNotFoundSelectors.contains(selector) {
            return .resolverNotFound
        }
        let stripped = revertHex.lowercased().hasPrefix("0x")
            ? revertHex.dropFirst(2) : revertHex[...]
        return stripped.isEmpty ? .dataless : .executionError
    }

    private func buildColibriTrust(
        client: ColibriENSClient,
        block: ENSBlock,
        system: NameSystem = .ens
    ) -> ENSTrust {
        ENSTrust(
            level: .verified,
            system: system,
            method: .colibri,
            block: block,
            agreed: [client.activeProverHost],
            dissented: [],
            queried: [client.activeProverHost],
            k: 1, m: 1
        )
    }

    /// The "provider" of a Myotis result is the device's own light
    /// client — surfaced under this label in the trust popover. The
    /// block is the engine's verified EL head (display context; 0 when
    /// not yet reported), with no hash: the anchoring is beacon
    /// finality, not a pinned quorum block.
    static let myotisProviderLabel = "embedded P2P light client"

    private func buildMyotisTrust(
        client: MyotisENSClient,
        system: NameSystem = .ens
    ) -> ENSTrust {
        ENSTrust(
            level: .verified,
            system: system,
            method: .myotis,
            block: ENSBlock(number: client.verifiedBlockNumber, hash: ""),
            agreed: [Self.myotisProviderLabel],
            dissented: [],
            queried: [Self.myotisProviderLabel],
            k: 1, m: 1
        )
    }

    /// The direct tier: one unverified answer from the first provider
    /// that can give one. Iterates the (shuffled, non-quarantined) pool
    /// on transport / anchor / leg failure, quarantining as it goes, so
    /// a dead first provider degrades to the next one instead of to
    /// "all providers failed" (desktop's direct tier walks the list the
    /// same way). A deterministic answer — data, a verified negative,
    /// a custom-RPC failure — ends the walk.
    private func resolveDirect(
        candidates: [URL],
        dnsEncodedName: Data,
        callData: Data,
        timeout: TimeInterval,
        system: NameSystem = .ens
    ) async throws -> ConsensusResult {
        guard !candidates.isEmpty else { throw ConsensusError.noProviders }
        for url in candidates {
            try Task.checkCancellation()
            do {
                let result = try await resolveSingleSource(
                    url: url,
                    dnsEncodedName: dnsEncodedName, callData: callData,
                    timeout: timeout, system: system
                )
                pool.markSuccess(url)
                return result
            } catch ConsensusError.allErrored {
                log.info("[ens] direct provider failed, trying next host=\(url.hostOrAbsolute, privacy: .public)")
                pool.markFailure(url)
                continue
            }
        }
        throw ConsensusError.allErrored
    }

    private func resolveSingleSource(
        url: URL,
        level: ENSTrustLevel = .unverified,
        dnsEncodedName: Data,
        callData: Data,
        timeout: TimeInterval,
        system: NameSystem = .ens
    ) async throws -> ConsensusResult {
        let pinned: AnchorCorroboration.PinnedBlock
        do {
            pinned = try await anchor.singleSourceAnchor(url: url)
        } catch {
            throw ConsensusError.allErrored
        }
        let leg = await legRunner(url, dnsEncodedName, callData, pinned.hash, timeout, settings.enableCcipRead, system)
        let ensBlock = ENSBlock(number: pinned.number, hash: pinned.hash)
        let trust = buildTrust(
            level: level, system: system, agreed: [url],
            queried: [url], k: 1, m: 1, block: ensBlock
        )
        switch leg.kind {
        case .data(let bytes, let resolver):
            return .data(resolvedData: bytes, resolverAddress: resolver, trust: trust)
        case .notFound(let reason):
            return .notFound(reason: reason, trust: trust)
        case .error:
            throw ConsensusError.allErrored
        }
    }

    private func resolveCustomRPC(
        dnsEncodedName: Data,
        callData: Data,
        timeout: TimeInterval,
        system: NameSystem = .ens
    ) async throws -> ConsensusResult {
        let trimmed = settings.ensRpcUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else {
            throw ENSResolutionError.customRpcFailed
        }
        do {
            return try await resolveSingleSource(
                url: url, level: .userConfigured,
                dnsEncodedName: dnsEncodedName, callData: callData,
                timeout: timeout, system: system
            )
        } catch {
            throw ENSResolutionError.customRpcFailed
        }
    }

    private func buildResult(
        from wave: QuorumWave.Outcome,
        block: AnchorCorroboration.PinnedBlock,
        system: NameSystem = .ens
    ) throws -> ConsensusResult {
        let ensBlock = ENSBlock(number: block.number, hash: block.hash)

        func trust(level: ENSTrustLevel, agreed: [URL], dissented: [URL] = []) -> ENSTrust {
            buildTrust(
                level: level, system: system, agreed: agreed, dissented: dissented,
                queried: wave.queried, k: wave.queried.count, m: wave.mUsed,
                block: ensBlock
            )
        }

        switch wave.resolution {
        case .data(let bytes, let resolver, let urls, let tier):
            return .data(
                resolvedData: bytes, resolverAddress: resolver,
                trust: trust(level: tier.level, agreed: urls)
            )
        case .notFound(let reason, let urls, let tier):
            return .notFound(reason: reason, trust: trust(level: tier.level, agreed: urls))
        case .conflict:
            return .conflict(
                groups: buildConflictGroups(from: wave),
                trust: trust(level: .conflict, agreed: [], dissented: wave.queried)
            )
        case .allErrored:
            throw ConsensusError.allErrored
        }
    }

    private func buildTrust(
        level: ENSTrustLevel,
        system: NameSystem = .ens,
        agreed: [URL],
        dissented: [URL] = [],
        queried: [URL],
        k: Int, m: Int,
        block: ENSBlock
    ) -> ENSTrust {
        // `.userConfigured` level means the custom-RPC fast path produced
        // the result — method matches the level. Every other path through
        // here is quorum (single-source falls under quorum semantically
        // since a future re-resolution should attempt the full wave).
        let method: ENSResolutionMethod = level == .userConfigured ? .userConfigured : .quorum
        return ENSTrust(
            level: level, system: system, method: method, block: block,
            agreed: agreed.map(\.hostOrAbsolute),
            dissented: dissented.map(\.hostOrAbsolute),
            queried: queried.map(\.hostOrAbsolute),
            k: k, m: m
        )
    }

    private func buildConflictGroups(from wave: QuorumWave.Outcome) -> [ENSConflictGroup] {
        var groups: [ENSConflictGroup] = []
        for (bytes, urls) in wave.byData {
            groups.append(ENSConflictGroup(
                resolvedData: bytes, reason: nil,
                hosts: urls.map(\.hostOrAbsolute)
            ))
        }
        for (reason, urls) in wave.byNegative {
            groups.append(ENSConflictGroup(
                resolvedData: nil, reason: reason,
                hosts: urls.map(\.hostOrAbsolute)
            ))
        }
        return groups
    }

    // MARK: - Forward address resolution

    /// Cache key for chain-scoped lookups: mainnet keeps the bare name so
    /// existing entries stay valid; other chains are prefixed so a Base
    /// address can never be served for an Ethereum send or vice versa.
    static func chainCacheKey(_ normalized: String, chainID: Int) -> String {
        chainID == Chain.mainnetID ? normalized : "\(chainID):\(normalized)"
    }

    /// Resolve an ENS name to its address on `chainID`. Same consensus
    /// pipeline as `resolveContent` — a lying RPC could otherwise misroute
    /// the user's funds — just with a different selector and a different
    /// success-payload decode. Resolution always starts on mainnet (the
    /// ENS registry lives there); the destination chain only picks the
    /// ENSIP-11 coin type, so an L2 send gets the name's record *for that
    /// chain* and never silently falls back to the Ethereum address.
    func resolveAddress(_ name: String, chainID: Int = Chain.mainnetID) async throws -> EthereumAddress {
        let normalized: String
        do {
            normalized = try name.ensNormalized()
        } catch {
            throw ENSResolutionError.invalidName
        }
        guard UniversalResolverABI.coinType(forChainID: chainID) != nil else {
            throw ENSResolutionError.unsupportedChain(chainID: chainID)
        }

        let key = Self.chainCacheKey(normalized, chainID: chainID)
        if let cached = addressCache[key], clock() < cached.expiresAt {
            return try cached.outcome.get()
        }
        if let task = addressInFlight[key] {
            return try await task.value.get()
        }

        let task = Task { @MainActor in
            let outcome = await self.doResolveAddress(normalized, chainID: chainID)
            guard !Task.isCancelled else {
                self.addressInFlight.removeValue(forKey: key)
                return outcome
            }
            self.storeAddress(key: key, outcome: outcome)
            return outcome
        }
        addressInFlight[key] = task
        return try await task.value.get()
    }

    private func doResolveAddress(
        _ normalized: String,
        chainID: Int
    ) async -> Result<EthereumAddress, ENSResolutionError> {
        let dnsEncoded: Data
        do {
            dnsEncoded = try ENSNameEncoding.dnsEncode(normalized)
        } catch {
            return .failure(.invalidName)
        }
        let system = NameSystem.forName(normalized)
        // The NameNFT registries (WNS/GNS) only carry the legacy
        // `addr(bytes32)` record. Off mainnet that record is the wrong
        // chain's address, so refuse rather than misroute (desktop parity).
        if chainID != Chain.mainnetID, system.contractAddress != nil {
            return .failure(.notSupportedOnChain(system: system, chainID: chainID))
        }
        let node = ENSNameEncoding.namehash(normalized)
        guard let callData = UniversalResolverABI.addrCallData(node: node, chainID: chainID) else {
            return .failure(.unsupportedChain(chainID: chainID))
        }

        let consensus: ConsensusResult
        do {
            consensus = try await consensusResolve(
                dnsEncodedName: dnsEncoded, callData: callData, system: system
            )
        } catch let err as AnchorCorroboration.AnchorError {
            if case .hashDisagreement(let largest, let total, let threshold) = err {
                return .failure(.anchorDisagreement(
                    largestBucketSize: largest, total: total, threshold: threshold
                ))
            }
            return .failure(.allProvidersErrored)
        } catch ENSResolutionError.customRpcFailed {
            return .failure(.customRpcFailed)
        } catch {
            return .failure(.allProvidersErrored)
        }

        switch consensus {
        case .data(let abiEncoded, _, let trust):
            // QuorumLeg already strips UR's outer `(bytes result, address)`
            // — what's left is the inner return: a padded `address` for
            // `addr(bytes32)`, ABI `bytes` for the multicoin record.
            guard let address = UniversalResolverABI.decodeAddrResponse(abiEncoded, chainID: chainID) else {
                return .failure(.notFound(reason: .emptyAddress, trust: trust))
            }
            // Zero address / empty bytes is ENS's "no address record set".
            if address == EthereumAddress.zero {
                return .failure(.notFound(reason: .emptyAddress, trust: trust))
            }
            return .success(address)
        case .notFound(let reason, let trust):
            return .failure(.notFound(reason: reason, trust: trust))
        case .conflict(let groups, let trust):
            return .failure(.conflict(groups: groups, trust: trust))
        }
    }

    private func storeAddress(
        key: String,
        outcome: Result<EthereumAddress, ENSResolutionError>
    ) {
        if let ttl = addressTTL(for: outcome) {
            addressCache[key] = AddressCacheEntry(
                outcome: outcome,
                expiresAt: clock().addingTimeInterval(ttl)
            )
            capAddressCache()
        }
        addressInFlight.removeValue(forKey: key)
    }

    /// Returns nil for transient failures (network) so retries can hit the
    /// network; matches the content-cache policy.
    private func addressTTL(for outcome: Result<EthereumAddress, ENSResolutionError>) -> TimeInterval? {
        switch outcome {
        case .success: return 15 * 60
        case .failure(.allProvidersErrored), .failure(.customRpcFailed): return nil
        case .failure(.conflict), .failure(.anchorDisagreement): return 10
        // Deterministic from the inputs alone — no network answer to age.
        case .failure(.notSupportedOnChain), .failure(.unsupportedChain): return 15 * 60
        case .failure: return 60
        }
    }

    private func capAddressCache() {
        guard addressCache.count > Self.maxCacheEntries else { return }
        let now = clock()
        addressCache = addressCache.filter { $0.value.expiresAt > now }
        while addressCache.count > Self.maxCacheEntries, let key = addressCache.keys.first {
            addressCache.removeValue(forKey: key)
        }
    }

    // MARK: - Reverse resolution

    /// Reverse-resolve an address to its ENS primary name for `chainID`
    /// (ENSIP-19: the UR's `reverse(bytes,uint256)` takes the coin type,
    /// so an L2 primary name is looked up as such and an Ethereum
    /// primary is never shown for a Base address). Returns
    /// `.verified(name)` for a forward-verified primary,
    /// `.unverified(claimedName)` when the contract surfaces a
    /// `ReverseAddressMismatch` (the on-chain spoof signal), or `.none`
    /// when no primary is set / the call failed. Single-shot via the
    /// wallet's RPC pool against Mainnet UR — display-only, so the
    /// consensus wave isn't worth the latency.
    func reverseResolve(
        address: EthereumAddress,
        chainID: Int = Chain.mainnetID
    ) async throws -> ENSReverseResolution {
        guard let coinType = UniversalResolverABI.coinType(forChainID: chainID) else {
            throw ENSResolutionError.unsupportedChain(chainID: chainID)
        }
        let key = Self.chainCacheKey(address.asString().lowercased(), chainID: chainID)
        if let cached = reverseCache[key], clock() < cached.expiresAt {
            return cached.result
        }
        var result = try await fetchReverseName(address: address, coinType: coinType)
        // Desktop's contract-backed reverse fallback: only when ENS
        // positively has no primary name (not on transport failure, which
        // throws above) do we consult the WNS/GNS registries — and only
        // on mainnet, where their records live.
        if case .none = result, chainID == Chain.mainnetID,
           let fallback = await contractBackedReverse(address: address) {
            result = fallback
        }
        let ttl: TimeInterval
        switch result {
        case .verified, .unverified:
            // `.unverified` is a deterministic on-chain state — the
            // reverse record's claimed name doesn't forward-resolve,
            // which only flips with an on-chain tx. Cache the same as
            // `.verified` so we don't re-hit the UR every minute for
            // a spoofed address.
            ttl = 15 * 60
        case .none:
            ttl = 60
        }
        reverseCache[key] = ReverseCacheEntry(
            result: result,
            expiresAt: clock().addingTimeInterval(ttl)
        )
        capReverseCache()
        return result
    }

    private func capReverseCache() {
        guard reverseCache.count > Self.maxCacheEntries else { return }
        let now = clock()
        reverseCache = reverseCache.filter { $0.value.expiresAt > now }
        while reverseCache.count > Self.maxCacheEntries, let key = reverseCache.keys.first {
            reverseCache.removeValue(forKey: key)
        }
    }

    private func fetchReverseName(
        address: EthereumAddress,
        coinType: BigUInt
    ) async throws -> ENSReverseResolution {
        // The same resolution order as forward lookups. Reverse is
        // display-only and single-shot on the RPC side, so the quorum and
        // Direct RPC methods share one provider walk: the user's own
        // endpoint first when Direct is enabled, then the public pool.
        let enabled = settings.ensEnabledResolutionMethods
        let timeout = TimeInterval(settings.ensQuorumTimeoutMs) / 1000
        var rpcWalkDone = false
        for method in enabled {
            try Task.checkCancellation()
            switch method {
            case .myotis:
                guard let myotis, myotis.isAvailable, !myotisCoolingDown else { continue }
                let hasLater = enabled.last != .myotis
                let wait = hasLater ? min(timeout, myotisDeadline ?? timeout) : timeout
                do {
                    let result = try await boundedMyotis(wait: wait) {
                        try await self.myotisReverse(address: address, coinType: coinType, client: myotis)
                    }
                    noteMyotisServed()
                    return result
                } catch let err as ColibriENSError {
                    log.info(
                        "[ens] myotis-fallthrough reverse address=\(address.asString(), privacy: .public) error=\(String(describing: err), privacy: .public)"
                    )
                    noteMyotisFallthrough()
                } catch is ChainSourceDeadline {
                    noteMyotisFallthrough()
                    noteMyotisTimeout()
                }
            case .colibri:
                guard let colibri else { continue }
                do {
                    return try await withSourceDeadline(timeout, source: .colibri) {
                        try await self.colibriReverse(address: address, coinType: coinType, client: colibri)
                    }
                } catch let err as ColibriENSError {
                    log.warning(
                        "[ens] colibri-fallback reverse address=\(address.asString(), privacy: .public) error=\(String(describing: err), privacy: .public)"
                    )
                }
            case .quorum, .userConfigured:
                guard !rpcWalkDone else { continue }
                rpcWalkDone = true
                var providers: [URL] = []
                if enabled.contains(.userConfigured), let custom = customRPCURL() { providers.append(custom) }
                if enabled.contains(.quorum) || providers.isEmpty { providers += pool.availableProviders() }
                do {
                    return try await reverseViaProviders(providers, address: address, coinType: coinType)
                } catch ReverseError.allProvidersFailed {
                    continue
                }
            case .direct:
                continue
            }
        }
        throw ReverseError.allProvidersFailed
    }

    /// The user's Direct RPC endpoint, when it parses as an http(s) URL.
    private func customRPCURL() -> URL? {
        let trimmed = settings.ensRpcUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    private func reverseViaProviders(
        _ providers: [URL],
        address: EthereumAddress,
        coinType: BigUInt
    ) async throws -> ENSReverseResolution {
        guard !providers.isEmpty else { throw ReverseError.allProvidersFailed }

        let callData = try UniversalResolverABI.encodeReverse(address: address, coinType: coinType)
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_call",
            "params": [
                ["to": Self.universalResolverAddress.asString(), "data": callData.web3.hexString],
                "latest",
            ],
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let timeout = TimeInterval(settings.ensQuorumTimeoutMs) / 1000

        // Iterate providers on transport / parse / RPC-error failure so a
        // single flaky RPC doesn't poison the result. The UR catches
        // inner reverts and returns empty for on-chain primary names
        // that forward-verify. Two reverts DO bubble up:
        //  - `OffchainLookup` (EIP-3668) for primary names behind a
        //    CCIP gateway (e.g. avsa.eth via Namestone). CCIP retry.
        //  - `ReverseAddressMismatch` when the on-chain reverse record
        //    claims a name that does NOT forward-resolve back to the
        //    address. The spoof signal — surface as `.unverified` with
        //    the claimed name decoded from the revert data.
        for url in providers {
            let response: Data
            do {
                response = try await reverseTransport(url, bodyData, timeout)
            } catch {
                continue
            }
            guard let envelope = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any] else {
                continue
            }
            if let error = envelope["error"] as? [String: Any] {
                if let revertHex = error["data"] as? String,
                   UniversalResolverABI.isReverseAddressMismatch(revertHex: revertHex) {
                    return .unverified(
                        claimedName: UniversalResolverABI.decodeReverseMismatchClaimedName(revertHex: revertHex)
                    )
                }
                if let primary = try await ccipRetry(error: error, providerURL: url, timeout: timeout) {
                    return primary.isEmpty ? .none : .verified(name: primary)
                }
                // Any other revert *with data* is the contract answering:
                // no reverse resolver / no record for this coin type (the
                // UR wraps it as `ResolverError`, which is what an L2 coin
                // type with no primary produces). Display-only lookup, so
                // "no primary" is the terminal answer — not a provider
                // fault to rotate past. Dataless errors and failed CCIP
                // hops still try the next provider.
                if let revertHex = error["data"] as? String,
                   CCIPResolver.selectorOf(revertHex) != CCIPResolver.offchainLookupSelector,
                   !(revertHex.web3.hexData ?? Data()).isEmpty {
                    return .none
                }
                continue
            }
            guard let resultHex = envelope["result"] as? String,
                  let primary = UniversalResolverABI.decodeReverseResponse(resultHex) else {
                continue
            }
            return primary.isEmpty ? .none : .verified(name: primary)
        }
        // Every provider failed — transient, not cacheable. Caller's `try?`
        // turns this into a silent .none-ish via XCTUnwrap of the throw.
        throw ReverseError.allProvidersFailed
    }

    // MARK: - NameNFT reverse fallback (WNS/GNS)

    /// Ask each NameNFT registry's `reverseResolve(address)` in turn and
    /// return the first claim that forward-verifies. Unlike the UR, the
    /// NameNFT contracts don't verify reverse records on-chain, so a claim
    /// only becomes `.verified` after `resolveAddress(claimedName)` round-
    /// trips to the same address through the full consensus pipeline. A
    /// claim that fails verification doesn't stop the next system (an
    /// address can carry a stale .wei record but a valid .gwei primary);
    /// the first unverified claim is kept as a fallback so its spoof
    /// warning still surfaces when nothing verifies. Nil = no system
    /// claimed anything.
    private func contractBackedReverse(address: EthereumAddress) async -> ENSReverseResolution? {
        var firstUnverified: ENSReverseResolution?
        for system in NameSystem.contractBacked {
            guard let contract = system.contractAddress,
                  let claimed = await nameNftReverseName(contract: contract, address: address),
                  !claimed.isEmpty else { continue }
            let verdict = await verifyContractBackedClaim(claimed, system: system, address: address)
            if case .verified = verdict { return verdict }
            if firstUnverified == nil { firstUnverified = verdict }
        }
        return firstUnverified
    }

    private func verifyContractBackedClaim(
        _ claimed: String,
        system: NameSystem,
        address: EthereumAddress
    ) async -> ENSReverseResolution {
        // A registry claiming a name outside its own suffix is inherently
        // unverifiable — forward resolution would consult a different
        // system than the one that made the claim.
        guard NameSystem.forName(claimed) == system else {
            return .unverified(claimedName: claimed)
        }
        guard let forward = try? await resolveAddress(claimed),
              forward.asString().lowercased() == address.asString().lowercased() else {
            return .unverified(claimedName: claimed)
        }
        return .verified(name: claimed)
    }

    /// Single-shot `reverseResolve(address)` eth_call against a NameNFT
    /// registry — display-only (same rationale as the ENS reverse path,
    /// which also skips the consensus wave). Iterates providers on
    /// transport/parse failure; an RPC error object means the contract
    /// answered (revert / no record), so that ends the lookup for this
    /// system rather than burning the remaining providers.
    private func nameNftReverseName(
        contract: EthereumAddress,
        address: EthereumAddress
    ) async -> String? {
        guard let callData = try? NameNFTABI.encodeReverseResolve(address: address) else {
            return nil
        }
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_call",
            "params": [
                ["to": contract.asString(), "data": callData.web3.hexString],
                "latest",
            ],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }
        let timeout = TimeInterval(settings.ensQuorumTimeoutMs) / 1000
        for url in pool.availableProviders() {
            guard let response = try? await reverseTransport(url, bodyData, timeout),
                  let envelope = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any]
            else { continue }
            if envelope["error"] != nil { return nil }
            guard let resultHex = envelope["result"] as? String,
                  let name = NameNFTABI.decodeStringResponse(resultHex) else {
                continue
            }
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// Cryptographically-verified reverse via Colibri. A `ColibriError`
    /// revert carries the raw revert data: `ReverseAddressMismatch`
    /// decodes to `.unverified(claimedName:)` (the spoof signal), any
    /// other revert (e.g. `ResolverNotFound`) means no primary is set.
    private func colibriReverse(
        address: EthereumAddress,
        coinType: BigUInt,
        client: ColibriENSClient
    ) async throws -> ENSReverseResolution {
        do {
            let name = try await client.universalResolverReverse(address: address, coinType: coinType)
            return name.isEmpty ? .none : .verified(name: name)
        } catch ColibriENSError.revert(let revertHex) {
            return try await provenReverseRevert(revertHex) { to, dataHex in
                try await client.ccipCallback(to: to, dataHex: dataHex)
            }
        }
    }

    /// Mirror of `colibriReverse` for the P2P tier — same UR revert
    /// vocabulary, same spoof decode.
    private func myotisReverse(
        address: EthereumAddress,
        coinType: BigUInt,
        client: MyotisENSClient
    ) async throws -> ENSReverseResolution {
        do {
            let name = try await client.universalResolverReverse(address: address, coinType: coinType)
            return name.isEmpty ? .none : .verified(name: name)
        } catch ColibriENSError.revert(let revertHex) {
            return try await provenReverseRevert(revertHex) { to, dataHex in
                try await client.ccipCallback(to: to, dataHex: dataHex)
            }
        }
    }

    /// Shared revert handling for `UR.reverse()` on the proven tiers:
    /// `ReverseAddressMismatch` is the spoof signal; `OffchainLookup`
    /// means the primary name lives behind a CCIP gateway (Namestone
    /// et al.) and is driven through the same verifier; the UR's
    /// not-found errors mean no primary is set; anything else is a
    /// proved execution failure and falls through to the next tier.
    private func provenReverseRevert(
        _ revertHex: String,
        call: @escaping CCIPResolver.EthCallExecutor
    ) async throws -> ENSReverseResolution {
        if UniversalResolverABI.isReverseAddressMismatch(revertHex: revertHex) {
            return .unverified(
                claimedName: UniversalResolverABI.decodeReverseMismatchClaimedName(revertHex: revertHex)
            )
        }
        switch Self.classifyColibriRevert(revertHex) {
        case .offchainLookup:
            guard settings.enableCcipRead else { return .none }
            let hex = try await provenCCIP(revertHex: revertHex, call: call)
            let primary = UniversalResolverABI.decodeReverseResponse(hex) ?? ""
            return primary.isEmpty ? .none : .verified(name: primary)
        case .resolverNotFound:
            return .none
        case .dataless, .executionError:
            throw ColibriENSError.proofFailed(message: "reverse resolver execution error — falling through")
        }
    }

    /// nil for any shape other than a CCIP-Read-eligible OffchainLookup
    /// whose gateway hop succeeded; caller falls through.
    private func ccipRetry(
        error: [String: Any],
        providerURL: URL,
        timeout: TimeInterval
    ) async throws -> String? {
        guard settings.enableCcipRead,
              let revertHex = error["data"] as? String,
              CCIPResolver.selectorOf(revertHex) == CCIPResolver.offchainLookupSelector,
              let revertBytes = revertHex.web3.hexData else {
            return nil
        }
        let resultHex: String
        do {
            resultHex = try await RPCSession.withTimeout(seconds: timeout * 2) {
                try await CCIPResolver.resolve(
                    revertData: revertBytes,
                    sender: Self.universalResolverAddress.asString(),
                    ethCall: { [transport = self.reverseTransport] target, callHex in
                        try await Self.reverseEthCall(
                            transport: transport,
                            providerURL: providerURL,
                            to: target,
                            dataHex: callHex,
                            timeout: timeout
                        )
                    },
                    http: self.reverseCCIPHTTP,
                    timeout: timeout
                )
            }
        } catch {
            return nil
        }
        return UniversalResolverABI.decodeReverseResponse(resultHex)
    }

    enum ReverseError: Error {
        case allProvidersFailed
    }

    /// CCIP callback eth_call against the same provider URL we got the
    /// OffchainLookup revert from. Surfaces revert-with-data as
    /// `RPCError.executionRevert` — the boundary contract that
    /// `CCIPResolver.resolve` expects so it can recurse on nested
    /// OffchainLookup reverts.
    private static func reverseEthCall(
        transport: @Sendable (URL, Data, TimeInterval) async throws -> Data,
        providerURL: URL,
        to: String,
        dataHex: String,
        timeout: TimeInterval
    ) async throws -> String {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_call",
            "params": [["to": to, "data": dataHex], "latest"],
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let response = try await transport(providerURL, bodyData, timeout)
        guard let envelope = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any] else {
            throw ReverseError.allProvidersFailed
        }
        // CCIPResolver.resolve catches inner OffchainLookup reverts via
        // `RPCError.executionRevert`, so we surface revert-with-data in
        // that shape; non-revert errors throw transparently.
        if let error = envelope["error"] as? [String: Any] {
            let revert = error["data"] as? String
            throw RPCError.executionRevert(data: revert)
        }
        guard let result = envelope["result"] as? String, !result.isEmpty else {
            throw ReverseError.allProvidersFailed
        }
        return result
    }

    // MARK: - Address cache state

    private struct AddressCacheEntry {
        let outcome: Result<EthereumAddress, ENSResolutionError>
        let expiresAt: Date
    }

    private struct ReverseCacheEntry {
        let result: ENSReverseResolution
        let expiresAt: Date
    }
}
