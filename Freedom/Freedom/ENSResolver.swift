import Foundation
import web3
import ENSNormalize

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
    // DAO-owned proxy so future UR impl upgrades don't require a client change.
    // https://docs.ens.domains/resolvers/universal/
    static let universalResolverAddress: EthereumAddress = "0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe"

    enum ConsensusResult {
        case data(resolvedData: Data, resolverAddress: EthereumAddress, trust: ENSTrust)
        case notFound(reason: ENSNotFoundReason, trust: ENSTrust)
        case conflict(groups: [ENSConflictGroup], trust: ENSTrust)
    }

    enum ConsensusError: Error {
        case noProviders
        case allErrored
        case ccipNotImplemented
    }

    // bytes4(keccak256("contenthash(bytes32)")) — the resolver call we
    // wrap in the Universal Resolver's resolve(name, data).
    private static let contenthashSelector = Data([0xbc, 0x1c, 0x58, 0xd1])

    private let pool: EthereumRPCPool
    private let settings: SettingsStore
    private let anchor: AnchorCorroboration
    private let legRunner: QuorumWave.LegRunner
    private let clock: () -> Date

    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<CachedOutcome, Never>] = [:]

    init(
        pool: EthereumRPCPool,
        settings: SettingsStore,
        anchor: AnchorCorroboration? = nil,
        legRunner: @escaping QuorumWave.LegRunner = QuorumWave.defaultLegRunner,
        clock: @escaping () -> Date = Date.init
    ) {
        self.pool = pool
        self.settings = settings
        self.anchor = anchor ?? AnchorCorroboration(pool: pool, settings: settings)
        self.legRunner = legRunner
        self.clock = clock
    }

    // MARK: - Public entry

    /// Resolve an ENS name to a navigable content URL. Normalizes via
    /// ENSIP-15 (adraffy/ENSNormalize), computes the namehash, runs the
    /// consensus pipeline, decodes the contenthash. Concurrent calls for
    /// the same normalized name share one Task; successful results are
    /// cached with trust-tier-specific TTLs matching desktop (verified
    /// 15min, unverified 60s, conflict 10s negative cache).
    /// Clears the name cache, cancels in-flight resolutions, and resets
    /// the anchor cache + pool quarantine. Call after a settings edit so
    /// stale verifications don't linger against the new configuration.
    func invalidate() {
        cache.removeAll()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        anchor.invalidate()
        pool.invalidate()
    }

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
        if case .transient = outcome {
            // Don't pin transient failures; let retries re-attempt fresh.
        } else {
            cache[normalized] = CacheEntry(
                outcome: outcome,
                expiresAt: clock().addingTimeInterval(outcome.ttl)
            )
            capCache()
        }
        inFlight.removeValue(forKey: normalized)
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

        let consensus: ConsensusResult
        do {
            consensus = try await consensusResolve(dnsEncodedName: dnsEncoded, callData: callData)
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
        } catch ConsensusError.ccipNotImplemented {
            // Distinct from generic "all errored" so the banner tells the
            // user the name needs CCIP rather than "check your network."
            return .failure(.ccipNotImplemented)
        } catch {
            // allErrored / noProviders / transport. Don't cache — retries
            // may succeed once the network recovers.
            return .transient
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
            guard let (uri, codec) = ContenthashDecoder.decode(innerBytes) else {
                return .failure(.unsupportedCodec(rawBytes: innerBytes, trust: trust))
            }
            return .success(ENSResolvedContent(name: normalized, uri: uri, codec: codec, trust: trust))
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
        /// Transient upstream failure (anchor disagreement, no providers,
        /// network). Sentinel marker — caller reinterprets as a thrown
        /// .allProvidersErrored and we don't cache it.
        case transient

        func unwrap() throws -> ENSResolvedContent {
            switch self {
            case .success(let c): return c
            case .failure(let e): throw e
            case .transient: throw ENSResolutionError.allProvidersErrored
            }
        }

        /// TTL per desktop's policy — verified answers are stable across
        /// short windows, unverified or conflict states shouldn't pin for
        /// long. The transient case short-TTLs to 0 so it's effectively
        /// unreachable in the cache path (the caller also skips caching).
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
            case .transient:
                return 0
            }
        }
    }

    // MARK: - Consensus orchestration

    /// Drives the quorum pipeline: feasibility → anchor → wave → optional
    /// second-wave → final trust-labelled result. Matches the desktop
    /// consensusResolve outcome taxonomy one-to-one.
    func consensusResolve(
        dnsEncodedName: Data,
        callData: Data
    ) async throws -> ConsensusResult {
        let available = pool.availableProviders()
        guard !available.isEmpty else { throw ConsensusError.noProviders }

        let desiredK = max(1, min(settings.ensQuorumK, 9))
        let desiredM = max(1, min(settings.ensQuorumM, desiredK))
        let timeout = TimeInterval(settings.ensQuorumTimeoutMs) / 1000
        let quorumDisabled = !settings.enableEnsQuorum
        let underpowered = desiredK < AnchorCorroboration.minQuorumProviders || desiredM < 2

        if quorumDisabled || underpowered || available.count < AnchorCorroboration.minQuorumProviders {
            return try await resolveSingleSource(
                url: available[0],
                dnsEncodedName: dnsEncodedName, callData: callData, timeout: timeout
            )
        }

        // getPinnedBlock throws on hash disagreement (security signal),
        // returns nil on runtime infeasibility (degrade to single-source).
        let pinned = try await anchor.getPinnedBlock()

        guard let block = pinned else {
            let fresh = pool.availableProviders()
            return try await resolveSingleSource(
                url: fresh.first ?? available[0],
                dnsEncodedName: dnsEncodedName, callData: callData, timeout: timeout
            )
        }

        // Refresh pool — anchor step may have quarantined flakes; reusing
        // the pre-anchor snapshot would waste the wave on dead providers.
        let waveAvailable = pool.availableProviders()
        if waveAvailable.count < AnchorCorroboration.minQuorumProviders {
            return try await resolveSingleSource(
                url: waveAvailable.first ?? available[0],
                dnsEncodedName: dnsEncodedName, callData: callData, timeout: timeout
            )
        }

        let effectiveK = min(desiredK, waveAvailable.count)
        let effectiveM = min(desiredM, effectiveK)
        let firstSelection = Array(waveAvailable.prefix(effectiveK))

        var wave = await QuorumWave.run(
            providers: firstSelection,
            dnsEncodedName: dnsEncodedName, callData: callData,
            blockHash: block.hash, timeout: timeout, m: effectiveM,
            enableCcipRead: settings.enableCcipRead,
            legRunner: legRunner
        )

        // Second-wave escalation on all-errored only. Conflict and
        // unverified outcomes mean honest providers gave us answers and
        // retrying wouldn't flip the verdict.
        if case .allErrored = wave.resolution {
            let remaining = pool.availableProviders().filter { !firstSelection.contains($0) }
            if !remaining.isEmpty {
                let secondK = min(desiredK, remaining.count)
                let secondSelection = Array(remaining.prefix(secondK))
                wave = await QuorumWave.run(
                    providers: secondSelection,
                    dnsEncodedName: dnsEncodedName, callData: callData,
                    blockHash: block.hash, timeout: timeout,
                    m: min(desiredM, secondK),
                    enableCcipRead: settings.enableCcipRead,
                    legRunner: legRunner
                )
            }
        }

        return try buildResult(from: wave, block: block)
    }

    private func resolveSingleSource(
        url: URL,
        dnsEncodedName: Data,
        callData: Data,
        timeout: TimeInterval
    ) async throws -> ConsensusResult {
        let pinned: AnchorCorroboration.PinnedBlock
        do {
            pinned = try await anchor.singleSourceAnchor(url: url)
        } catch {
            throw ConsensusError.allErrored
        }
        let leg = await legRunner(url, dnsEncodedName, callData, pinned.hash, timeout, settings.enableCcipRead)
        let ensBlock = ENSBlock(number: pinned.number, hash: pinned.hash)
        let trust = buildTrust(
            level: .unverified, agreed: [url],
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

    private func buildResult(
        from wave: QuorumWave.Outcome,
        block: AnchorCorroboration.PinnedBlock
    ) throws -> ConsensusResult {
        let ensBlock = ENSBlock(number: block.number, hash: block.hash)

        func trust(level: ENSTrustLevel, agreed: [URL], dissented: [URL] = []) -> ENSTrust {
            buildTrust(
                level: level, agreed: agreed, dissented: dissented,
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
        case .ccipNotImplemented:
            throw ConsensusError.ccipNotImplemented
        }
    }

    private func buildTrust(
        level: ENSTrustLevel,
        agreed: [URL],
        dissented: [URL] = [],
        queried: [URL],
        k: Int, m: Int,
        block: ENSBlock
    ) -> ENSTrust {
        ENSTrust(
            level: level, block: block,
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
}
