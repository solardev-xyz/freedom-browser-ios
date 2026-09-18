import Foundation

/// A tier the chain-data router can ask for chain state, in the order
/// the chain's policy lists them. Raw values are the persisted form and
/// match desktop's `access.readOrder` entries (`chains.json`).
enum ChainSource: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Embedded P2P light client (mainnet + Gnosis).
    case myotis
    /// Remote prover, sync-committee proof (mainnet + Gnosis).
    case colibri
    /// M-of-K byte-identical agreement across the chain's RPC pool.
    case quorum
    /// First RPC endpoint that answers, unverified.
    case direct

    var id: String { rawValue }

    /// Whether an answer from this tier carries a proof or agreement.
    var isVerified: Bool { self != .direct }

    var displayName: String {
        switch self {
        case .myotis: "P2P light client"
        case .colibri: "Colibri"
        case .quorum: "RPC quorum"
        case .direct: "Direct RPC"
        }
    }

    /// Tiers that can broadcast a signed transaction.
    var canBroadcast: Bool { self == .myotis || self == .direct }
}

/// Per-chain routing policy — which tiers to try for reads and for
/// broadcast, and the quorum / prover parameters those tiers use.
/// Desktop parity: `network.access.readOrder` / `broadcastOrder` and
/// `network.quorum` in `network-registry.js`.
struct ChainAccessPolicy: Codable, Equatable, Sendable {
    var readOrder: [ChainSource]
    var broadcastOrder: [ChainSource]
    var quorumK: Int
    var quorumM: Int
    var quorumTimeoutMs: Int
    /// Colibri prover override; nil / empty means the binding's default
    /// for the chain.
    var proverURL: String?
    var zkProof: Bool

    static let defaultQuorumK = 3
    static let defaultQuorumM = 2
    static let defaultQuorumTimeoutMs = 5_000
    /// Desktop clamps every configured timeout to at least half a second.
    static let minimumTimeoutMs = 500

    /// Chains the embedded light client and the Colibri prover cover.
    /// A policy for any other chain can only use `quorum` and `direct`.
    static let lightClientChainIDs: Set<Int> = [Chain.mainnetID, Chain.gnosisID]

    static func supportedSources(forChainID id: Int) -> [ChainSource] {
        lightClientChainIDs.contains(id) ? ChainSource.allCases : [.quorum, .direct]
    }

    static func supports(_ source: ChainSource, chainID: Int) -> Bool {
        supportedSources(forChainID: chainID).contains(source)
    }

    /// Desktop's defaults: the full ladder where a light client exists,
    /// `quorum → direct` elsewhere (its Base entry), so a fresh Chainlist
    /// add gets verified reads as soon as its pool has ≥ K endpoints.
    static func `default`(forChainID id: Int) -> ChainAccessPolicy {
        let lightClient = lightClientChainIDs.contains(id)
        return ChainAccessPolicy(
            readOrder: lightClient ? [.myotis, .colibri, .quorum, .direct] : [.quorum, .direct],
            broadcastOrder: lightClient ? [.myotis, .direct] : [.direct],
            quorumK: defaultQuorumK,
            quorumM: defaultQuorumM,
            quorumTimeoutMs: defaultQuorumTimeoutMs,
            proverURL: nil,
            zkProof: true
        )
    }

    init(
        readOrder: [ChainSource],
        broadcastOrder: [ChainSource],
        quorumK: Int = ChainAccessPolicy.defaultQuorumK,
        quorumM: Int = ChainAccessPolicy.defaultQuorumM,
        quorumTimeoutMs: Int = ChainAccessPolicy.defaultQuorumTimeoutMs,
        proverURL: String? = nil,
        zkProof: Bool = true
    ) {
        self.readOrder = readOrder
        self.broadcastOrder = broadcastOrder
        self.quorumK = quorumK
        self.quorumM = quorumM
        self.quorumTimeoutMs = quorumTimeoutMs
        self.proverURL = proverURL
        self.zkProof = zkProof
    }

    /// `k ≥ 1`, `1 ≤ m ≤ k` — desktop's `requestQuorum` clamps the same way.
    var effectiveQuorumK: Int { max(1, quorumK) }
    var effectiveQuorumM: Int { max(1, min(effectiveQuorumK, quorumM)) }
    /// Configured source timeout, clamped to the desktop minimum.
    var sourceTimeout: TimeInterval {
        TimeInterval(max(Self.minimumTimeoutMs, quorumTimeoutMs)) / 1_000
    }

    /// Prover URL with whitespace trimmed; nil when unset.
    var trimmedProverURL: String? {
        guard let raw = proverURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    /// The policy as the router will actually apply it for `chainID`:
    /// duplicates dropped, tiers the chain cannot use dropped, an empty
    /// order replaced by `direct`, and the quorum numbers clamped.
    func sanitized(forChainID id: Int) -> ChainAccessPolicy {
        var out = self
        out.readOrder = Self.sanitizedOrder(readOrder, chainID: id, allowed: { _ in true })
        out.broadcastOrder = Self.sanitizedOrder(broadcastOrder, chainID: id, allowed: \.canBroadcast)
        out.quorumK = effectiveQuorumK
        out.quorumM = effectiveQuorumM
        out.quorumTimeoutMs = max(Self.minimumTimeoutMs, quorumTimeoutMs)
        out.proverURL = trimmedProverURL
        return out
    }

    private static func sanitizedOrder(
        _ order: [ChainSource],
        chainID: Int,
        allowed: (ChainSource) -> Bool
    ) -> [ChainSource] {
        var seen: Set<ChainSource> = []
        var out: [ChainSource] = []
        for source in order where allowed(source) && supports(source, chainID: chainID) && !seen.contains(source) {
            seen.insert(source)
            out.append(source)
        }
        return out.isEmpty ? [.direct] : out
    }
}

/// Who is asking. A page-driven read (the dapp bridge, the onchain-app
/// loader) supplies the page's permission key; wallet-internal reads
/// leave it nil. Only page-driven reads trade verification for
/// interactive latency in the router's adaptive layer.
struct RoutingContext: Equatable, Sendable {
    /// Canonical permission key of the page, or nil for the wallet.
    let origin: String?

    static let wallet = RoutingContext(origin: nil)

    /// Desktop's `normalizeRoutingOrigin`: trimmed, non-empty, at most
    /// 2048 characters, no control characters — otherwise the read is
    /// treated as wallet-internal. Case is preserved (CIDv0 keys are
    /// case-sensitive).
    init(origin: String?) {
        guard let raw = origin?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.count <= 2_048,
              !raw.unicodeScalars.contains(where: { $0.value <= 31 || $0.value == 127 }) else {
            self.origin = nil
            return
        }
        self.origin = raw
    }

    var isInteractive: Bool { origin != nil }
}

/// A chain read with its provenance: the JSON value the caller asked
/// for, the tier that produced it and the evidence behind it.
struct ChainDataResult {
    /// JSON-RPC `result` as a Foundation JSON value (`NSNull` for a
    /// well-defined null).
    let result: Any
    let trust: ENSTrust
    let source: ChainSource
}
