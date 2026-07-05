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

    enum ConsensusResult {
        case data(resolvedData: Data, resolverAddress: EthereumAddress, trust: ENSTrust)
        case notFound(reason: ENSNotFoundReason, trust: ENSTrust)
        case conflict(groups: [ENSConflictGroup], trust: ENSTrust)
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
        colibri: ColibriENSClient? = nil
    ) {
        self.pool = pool
        self.settings = settings
        self.anchor = anchor ?? AnchorCorroboration(pool: pool, settings: settings)
        self.legRunner = legRunner
        self.reverseTransport = reverseTransport
        self.reverseCCIPHTTP = reverseCCIPHTTP
        self.clock = clock
        self.colibri = colibri
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
            var components = URLComponents()
            components.scheme = codec.scheme
            components.host = normalized
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

        // Colibri primary: cryptographic verification via the sync committee
        // (or ZK sync proof). On verification failure or network/prover
        // error we log loudly and fall through to the legacy quorum path
        // below unless `ensFallbackToQuorum` is explicitly disabled.
        // Loud-fallback is load-bearing: silent fall-through would hide
        // both prover health regressions and the rare "active attack"
        // signal.
        if settings.ensResolutionMethod == .colibri, let colibri {
            do {
                return try await tryColibri(
                    dnsEncodedName: dnsEncodedName, callData: callData,
                    client: colibri, system: system
                )
            } catch let err as ColibriENSError {
                if !settings.ensFallbackToQuorum {
                    throw ENSResolutionError.allProvidersErrored
                }
                log.warning(
                    "[ens] colibri-fallback error=\(String(describing: err), privacy: .public)"
                )
                // fall through to legacy path
            }
        }

        // See ENSResolutionError.customRpcFailed — fail-closed by design.
        if settings.ensResolutionMethod == .userConfigured {
            return try await resolveCustomRPC(
                dnsEncodedName: dnsEncodedName, callData: callData,
                timeout: timeout, system: system
            )
        }

        let available = pool.availableProviders()
        guard !available.isEmpty else { throw ConsensusError.noProviders }

        let desiredK = max(1, min(settings.ensQuorumK, 9))
        let desiredM = max(1, min(settings.ensQuorumM, desiredK))
        let quorumDisabled = !settings.enableEnsQuorum
        let underpowered = desiredK < AnchorCorroboration.minQuorumProviders || desiredM < 2

        if quorumDisabled || underpowered || available.count < AnchorCorroboration.minQuorumProviders {
            return try await resolveSingleSource(
                url: available[0],
                dnsEncodedName: dnsEncodedName, callData: callData,
                timeout: timeout, system: system
            )
        }

        // getPinnedBlock throws on hash disagreement (security signal),
        // returns nil on runtime infeasibility (degrade to single-source).
        let pinned = try await anchor.getPinnedBlock()

        guard let block = pinned else {
            let fresh = pool.availableProviders()
            return try await resolveSingleSource(
                url: fresh.first ?? available[0],
                dnsEncodedName: dnsEncodedName, callData: callData,
                timeout: timeout, system: system
            )
        }

        // Refresh pool — anchor step may have quarantined flakes; reusing
        // the pre-anchor snapshot would waste the wave on dead providers.
        let waveAvailable = pool.availableProviders()
        if waveAvailable.count < AnchorCorroboration.minQuorumProviders {
            return try await resolveSingleSource(
                url: waveAvailable.first ?? available[0],
                dnsEncodedName: dnsEncodedName, callData: callData,
                timeout: timeout, system: system
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
            // An `OffchainLookup` revert means the name has content behind
            // a CCIP gateway — NOT "no content". Rethrow so the quorum
            // fallback (which drives CCIP via `CCIPResolver`) handles it.
            // Any other verified revert is a genuine "no contenthash"
            // outcome — same as desktop's NO_CONTENTHASH bucket.
            if CCIPResolver.selectorOf(revertHex) == CCIPResolver.offchainLookupSelector {
                throw ColibriENSError.revert(data: revertHex)
            }
            return .notFound(reason: .noContenthash, trust: trust)
        }
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

    // MARK: - Forward addr(bytes32) resolution

    private static let addrSelector = UniversalResolverABI.addrSelector

    /// Resolve an ENS name to its primary Ethereum address. Same consensus
    /// pipeline as `resolveContent` — a lying RPC could otherwise misroute
    /// the user's funds — just with a different selector and a different
    /// success-payload decode.
    func resolveAddress(_ name: String) async throws -> EthereumAddress {
        let normalized: String
        do {
            normalized = try name.ensNormalized()
        } catch {
            throw ENSResolutionError.invalidName
        }

        if let cached = addressCache[normalized], clock() < cached.expiresAt {
            return try cached.outcome.get()
        }
        if let task = addressInFlight[normalized] {
            return try await task.value.get()
        }

        let task = Task { @MainActor in
            let outcome = await self.doResolveAddress(normalized)
            guard !Task.isCancelled else {
                self.addressInFlight.removeValue(forKey: normalized)
                return outcome
            }
            self.storeAddress(normalized: normalized, outcome: outcome)
            return outcome
        }
        addressInFlight[normalized] = task
        return try await task.value.get()
    }

    private func doResolveAddress(_ normalized: String) async -> Result<EthereumAddress, ENSResolutionError> {
        let dnsEncoded: Data
        do {
            dnsEncoded = try ENSNameEncoding.dnsEncode(normalized)
        } catch {
            return .failure(.invalidName)
        }
        let node = ENSNameEncoding.namehash(normalized)
        let callData = Self.addrSelector + node
        let system = NameSystem.forName(normalized)

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
            guard let address = decodeAddress(abiEncoded) else {
                return .failure(.notFound(reason: .emptyAddress, trust: trust))
            }
            // Zero address from `addr()` is ENS's "no address record set".
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

    private func decodeAddress(_ abiEncoded: Data) -> EthereumAddress? {
        // QuorumLeg already strips UR's outer `(bytes result, address)` —
        // for `addr() returns (address)` (static), `result` is just the
        // 32-byte ABI-padded address, no further `bytes` layer to unwrap.
        // Contrast with contenthash, where the inner return type IS
        // `bytes`, hence ContenthashDecoder.unwrapABIBytes there.
        guard let decoded = try? ABIDecoder.decodeData(
            abiEncoded.web3.hexString, types: [EthereumAddress.self]
        ).first else { return nil }
        return try? decoded.decoded()
    }

    private func storeAddress(
        normalized: String,
        outcome: Result<EthereumAddress, ENSResolutionError>
    ) {
        if let ttl = addressTTL(for: outcome) {
            addressCache[normalized] = AddressCacheEntry(
                outcome: outcome,
                expiresAt: clock().addingTimeInterval(ttl)
            )
            capAddressCache()
        }
        addressInFlight.removeValue(forKey: normalized)
    }

    /// Returns nil for transient failures (network) so retries can hit the
    /// network; matches the content-cache policy.
    private func addressTTL(for outcome: Result<EthereumAddress, ENSResolutionError>) -> TimeInterval? {
        switch outcome {
        case .success: return 15 * 60
        case .failure(.allProvidersErrored), .failure(.customRpcFailed): return nil
        case .failure(.conflict), .failure(.anchorDisagreement): return 10
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

    /// Reverse-resolve an Ethereum address to its ENS primary name.
    /// Returns `.verified(name)` for a forward-verified primary,
    /// `.unverified(claimedName)` when the contract surfaces a
    /// `ReverseAddressMismatch` (the on-chain spoof signal), or `.none`
    /// when no primary is set / the call failed. Single-shot via the
    /// wallet's RPC pool against Mainnet UR — display-only, so the
    /// consensus wave isn't worth the latency.
    func reverseResolve(address: EthereumAddress) async throws -> ENSReverseResolution {
        let key = address.asString().lowercased()
        if let cached = reverseCache[key], clock() < cached.expiresAt {
            return cached.result
        }
        var result = try await fetchReverseName(address: address)
        // Desktop's contract-backed reverse fallback: only when ENS
        // positively has no primary name (not on transport failure, which
        // throws above) do we consult the WNS/GNS registries.
        if case .none = result, let fallback = await contractBackedReverse(address: address) {
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

    private func fetchReverseName(address: EthereumAddress) async throws -> ENSReverseResolution {
        // Colibri primary path. On `ColibriENSError` we log loudly and
        // fall through to quorum unless `ensFallbackToQuorum` is disabled.
        if settings.ensResolutionMethod == .colibri, let colibri {
            do {
                return try await colibriReverse(address: address, client: colibri)
            } catch let err as ColibriENSError {
                if !settings.ensFallbackToQuorum {
                    throw ReverseError.allProvidersFailed
                }
                log.warning(
                    "[ens] colibri-fallback reverse address=\(address.asString(), privacy: .public) error=\(String(describing: err), privacy: .public)"
                )
            }
        }

        let providers = pool.availableProviders()
        guard !providers.isEmpty else { throw ReverseError.allProvidersFailed }

        let callData = try UniversalResolverABI.encodeReverse(address: address)
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
        client: ColibriENSClient
    ) async throws -> ENSReverseResolution {
        do {
            let name = try await client.universalResolverReverse(address: address)
            return name.isEmpty ? .none : .verified(name: name)
        } catch ColibriENSError.revert(let revertHex) {
            guard UniversalResolverABI.isReverseAddressMismatch(revertHex: revertHex) else {
                return .none
            }
            return .unverified(
                claimedName: UniversalResolverABI.decodeReverseMismatchClaimedName(revertHex: revertHex)
            )
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
