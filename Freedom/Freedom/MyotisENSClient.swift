import BigInt
import Foundation
import MyotisKit
import OSLog
import web3

private let log = Logger(subsystem: "com.browser.Freedom", category: "MyotisENS")

/// Fully peer-to-peer verified ENS resolution via the embedded Myotis
/// light client. Drives the same `eth_call` shapes as `ColibriENSClient`
/// (ENS Universal Resolver / NameNFT registries), but with **no remote
/// prover in the loop**: the engine executes the call in a local EVM over
/// snap-proof-served state whose root is anchored to beacon-chain
/// sync-committee finality. A successful return is therefore verified
/// end-to-end by this device against Ethereum's consensus — the strongest
/// trust tier the app has.
///
/// Errors reuse the `ColibriENSError` taxonomy on purpose: the resolver's
/// revert classification (`classifyColibriRevert`) and fall-through
/// plumbing are identical for both proven tiers, and a shared vocabulary
/// keeps `tryMyotis` a mirror of `tryColibri` instead of a divergent
/// re-implementation.
@MainActor
final class MyotisENSClient {
    typealias EthCall = @MainActor (_ to: String, _ dataHex: String) async -> MyotisCallOutcome

    private let availability: @MainActor () -> Bool
    private let verifiedBlock: @MainActor () -> UInt64
    private let ethCall: EthCall

    init(node: MyotisNode) {
        let chainId = MyotisNetwork.mainnet.chainId
        self.availability = { node.isReady(chainId: chainId) }
        self.verifiedBlock = {
            UInt64(max(0, node.chainStatus[chainId]?.executionBlockNumber ?? 0))
        }
        self.ethCall = { to, dataHex in
            await node.ethCall(chainId: chainId, to: to, data: dataHex)
        }
    }

    /// Closure seam for unit tests — mirrors how the resolver's other
    /// dependencies (legRunner, anchor fetchers) are injected.
    init(
        availability: @escaping @MainActor () -> Bool,
        verifiedBlock: @escaping @MainActor () -> UInt64 = { 0 },
        ethCall: @escaping EthCall
    ) {
        self.availability = availability
        self.verifiedBlock = verifiedBlock
        self.ethCall = ethCall
    }

    /// Whether the mainnet engine can plausibly serve a verified read
    /// *right now*: beacon-synced with at least one snap peer. The
    /// resolver skips the tier entirely when false — attempting a read
    /// during warm-up burns seconds on a doomed "state unavailable"
    /// (observed consistently in the Phase 0 spike) while Colibri could
    /// have answered immediately.
    var isAvailable: Bool { availability() }

    /// Verified execution-layer head, for trust display (0 when the
    /// engine hasn't reported one yet).
    var verifiedBlockNumber: UInt64 { verifiedBlock() }

    /// Universal Resolver `resolve(bytes name, bytes data)`. Mirrors
    /// `ColibriENSClient.universalResolverCall` so downstream decode is
    /// shared.
    func universalResolverCall(
        dnsEncodedName: Data,
        callData: Data
    ) async throws -> (resolvedData: Data, resolverAddress: EthereumAddress) {
        let encoded = try UniversalResolverABI.encodeResolve(name: dnsEncodedName, callData: callData)
        let hex = try await provenEthCall(to: UniversalResolverABI.address, callData: encoded)
        return try UniversalResolverABI.decodeResolveResponse(hex)
    }

    /// One proven eth_call straight to a NameNFT registry (WNS/GNS) —
    /// same shape as the Colibri variant, same shared downstream decode.
    func nameNftCall(
        contract: EthereumAddress,
        callData: Data
    ) async throws -> (resolvedData: Data, resolverAddress: EthereumAddress) {
        let hex = try await provenEthCall(to: contract, callData: callData)
        guard let bytes = hex.web3.hexData, !bytes.isEmpty else {
            throw ColibriENSError.unexpectedResponse(hex)
        }
        return (bytes, contract)
    }

    /// Universal Resolver `reverse(bytes,uint256)`. `ReverseAddressMismatch`
    /// reverts surface as `ColibriENSError.revert(data:)` exactly like the
    /// Colibri path, so the resolver's spoof decoding is shared.
    func universalResolverReverse(
        address: EthereumAddress,
        coinType: BigUInt = UniversalResolverABI.ethereumCoinType
    ) async throws -> String {
        let encoded = try UniversalResolverABI.encodeReverse(address: address, coinType: coinType)
        let hex = try await provenEthCall(to: UniversalResolverABI.address, callData: encoded)
        return UniversalResolverABI.decodeReverseResponse(hex) ?? ""
    }

    /// EIP-3668 callback executor: one proven eth_call with the
    /// `CCIPResolver` boundary contract — a revert with data surfaces as
    /// `RPCError.executionRevert` so the resolver can recurse on nested
    /// `OffchainLookup`s; every other failure keeps the
    /// `ColibriENSError` taxonomy so the tier falls through as usual.
    func ccipCallback(to: String, dataHex: String) async throws -> String {
        guard let callData = dataHex.web3.hexData else {
            throw ColibriENSError.unexpectedResponse(dataHex)
        }
        do {
            return try await provenEthCall(to: EthereumAddress(to), callData: callData)
        } catch ColibriENSError.revert(let data) {
            throw RPCError.executionRevert(data: data)
        }
    }

    /// One eth_call through the embedded engine, returning the proven
    /// return data as hex. `unavailable`/`error` outcomes map to
    /// `.proofFailed` — the resolver treats those as transient and falls
    /// through to the next tier unconditionally.
    private func provenEthCall(to: EthereumAddress, callData: Data) async throws -> String {
        let started = ContinuousClock.now
        let outcome = await ethCall(to.asString(), callData.web3.hexString)
        switch outcome {
        case .ok(let resultHex):
            // The one number that says whether the resolver's 2 s budget
            // for this tier is generous: a healthy engine answers in
            // milliseconds, a tip-lagging one never gets here.
            let ms = Int(Double(started.duration(to: .now).components.attoseconds) / 1e15)
                + Int(started.duration(to: .now).components.seconds) * 1_000
            log.info("[myotis] read served in \(ms)ms")
            return resultHex
        case .revert(let dataHex):
            throw ColibriENSError.revert(data: dataHex)
        case .unavailable(let reason):
            log.info("[myotis] read unavailable: \(reason, privacy: .public)")
            throw ColibriENSError.proofFailed(message: "myotis unavailable: \(reason)")
        case .error(let message):
            log.warning("[myotis] read failed: \(message, privacy: .public)")
            throw ColibriENSError.proofFailed(message: "myotis error: \(message)")
        }
    }
}
