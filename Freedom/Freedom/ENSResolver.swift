import Foundation
import web3

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
    }

    private let pool: EthereumRPCPool
    private let settings: SettingsStore
    private let anchor: AnchorCorroboration
    private let legRunner: QuorumWave.LegRunner

    init(
        pool: EthereumRPCPool,
        settings: SettingsStore,
        anchor: AnchorCorroboration? = nil,
        legRunner: @escaping QuorumWave.LegRunner = QuorumWave.defaultLegRunner
    ) {
        self.pool = pool
        self.settings = settings
        self.anchor = anchor ?? AnchorCorroboration(pool: pool, settings: settings)
        self.legRunner = legRunner
    }

    func resolveContent(_ name: String) async throws -> ENSResolvedContent {
        throw ENSResolutionError.notImplemented
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
        let leg = await legRunner(url, dnsEncodedName, callData, pinned.hash, timeout)
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
