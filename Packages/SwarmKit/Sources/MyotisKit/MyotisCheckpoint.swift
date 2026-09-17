import Foundation

/// Stale-anchor recovery, part 1: the checkpoint *policy* — network
/// constants, the persisted checkpoint record and its validation rules.
/// A byte-for-byte port of desktop freedom-browser's
/// `src/main/myotis/checkpoint-verifier.js` (PR #353): same sources,
/// same quorum thresholds, same freshness and clock rules, same error
/// taxonomy. Pure — no I/O — so the decision tables are unit-testable.
///
/// Why this exists: myotis v0.1.8+ enforces a weak-subjectivity gate.
/// When both the embedded checkpoint and the saved snapshot are older
/// than the bound (13 sync-committee periods on mainnet ≈ 14.7 days,
/// 3 on Gnosis ≈ 34 h) the engine parks in `beaconState:"STALE_ANCHOR"`
/// and refuses to sync — a forged continuation signed by since-exited
/// committee members would otherwise BLS-verify. The host must then
/// obtain a fresh checkpoint *by its own means* and bootstrap a fresh
/// generation from it (`myotis_create_with_checkpoint`). This file is
/// the "own means": an external checkpoint quorum, corroborated by a
/// Colibri committee-history proof (see `MyotisCheckpointAcquirer`).
public enum MyotisCheckpointError: String, Error, Sendable, Equatable, CaseIterable {
    /// Not enough checkpoint sources could confirm a recent checkpoint.
    case quorumUnavailable = "CHECKPOINT_QUORUM_UNAVAILABLE"
    /// Checkpoint sources disagree — terminal, never auto-retried.
    case quorumConflict = "CHECKPOINT_QUORUM_CONFLICT"
    /// A service could not complete verification (transport, malformed
    /// body, deadline). Retryable.
    case unavailable = "CHECKPOINT_UNAVAILABLE"
    /// The verifier contract is not what this build expects.
    case incompatible = "CHECKPOINT_INCOMPATIBLE"
    /// The checkpoint evidence did not pass verification.
    case mismatch = "CHECKPOINT_MISMATCH"
    /// The checkpoint is too old (> 1 h). Retryable — the next attempt
    /// asks for a fresher one.
    case stale = "CHECKPOINT_STALE"
    /// The finalized checkpoint moved during verification. Retryable.
    case race = "CHECKPOINT_RACE"
    /// Checkpoint time disagrees with this device's clock.
    case clock = "CHECKPOINT_CLOCK"
    /// Persisted sync state is inconsistent (anchor marker, pointer,
    /// generation record). "Repair sync data" starts a fresh generation.
    case storage = "CHECKPOINT_STORAGE"
    /// The filesystem refused (full, read-only, permissions).
    case storageIO = "CHECKPOINT_STORAGE_IO"
    /// The previous engine did not release its state directory.
    case ownership = "CHECKPOINT_OWNERSHIP"
    /// No checkpoint corroborator / no ABI-26 engine — update the app.
    case unsupported = "CHECKPOINT_UNSUPPORTED"

    /// Desktop's automatic-retry set. Everything else stops automatic
    /// retries and surfaces a user action.
    public var retryable: Bool {
        switch self {
        case .unavailable, .quorumUnavailable, .race, .stale: true
        default: false
        }
    }

    /// User-facing sentence (desktop `ERROR_MESSAGES` parity).
    public var message: String {
        switch self {
        case .quorumUnavailable: "Not enough checkpoint sources could confirm a recent checkpoint. Try again."
        case .quorumConflict: "Checkpoint sources disagree. Sync is paused."
        case .unavailable: "The checkpoint service could not complete verification. Try again."
        case .incompatible: "This checkpoint verifier is incompatible. Update Freedom to try again."
        case .mismatch: "The checkpoint evidence did not pass verification."
        case .stale: "The checkpoint is too old. Try again for a recent checkpoint."
        case .race: "The finalized checkpoint changed during verification. Try again."
        case .clock: "The checkpoint time does not agree with this device’s clock."
        case .storage: "The saved sync data is inconsistent. Repair sync data to start fresh."
        case .storageIO: "Freedom could not write sync data. Check free space and try again."
        case .ownership: "The previous light client did not release its sync data."
        case .unsupported: "Checkpoint recovery is unavailable in this build. Update Freedom."
        }
    }

    /// Any error thrown inside the acquisition pipeline that is not
    /// already a checkpoint error is a service failure, never a
    /// verification verdict.
    public static func wrap(_ error: Error) -> MyotisCheckpointError {
        if let known = error as? MyotisCheckpointError { return known }
        if error is CancellationError { return .unavailable }
        return .unavailable
    }
}

/// Per-chain checkpoint policy. Frozen constants — changing a source
/// list or a threshold is a trust-policy change and must be mirrored
/// with desktop `CHECKPOINT_NETWORKS`.
public struct MyotisCheckpointNetwork: Sendable, Equatable {
    public let chainId: UInt64
    /// Engine canonical network name (`myotis_create*` input).
    public let network: String
    /// Colibri's intercepted request origin (interception boundary
    /// only — not a mandatory individual voter).
    public let source: String
    /// Candidate pool in stable order. Replacement walks this order.
    public let sources: [String]
    /// Seats: how many candidates vote concurrently.
    public let participants: Int
    /// Agreeing votes required. Never reduced.
    public let threshold: Int
    /// Colibri prover for the committee-history proof.
    public let prover: String
    public let genesis: UInt64
    public let secondsPerSlot: UInt64
    public let slotsPerEpoch: UInt64

    public static let mainnet = MyotisCheckpointNetwork(
        chainId: 1,
        network: "mainnet",
        source: "https://mainnet.checkpoint.sigp.io",
        sources: [
            "https://mainnet.checkpoint.sigp.io",
            "https://beaconstate.ethstaker.cc",
            "https://beaconstate-mainnet.chainsafe.io",
            "https://mainnet-checkpoint-sync.attestant.io",
            "https://sync-mainnet.beaconcha.in",
            "https://checkpointz.pietjepuk.net",
            "https://mainnet-checkpoint-sync.stakely.io",
        ],
        participants: 3,
        threshold: 2,
        prover: "https://mainnet1.colibri-proof.tech",
        genesis: 1_606_824_023,
        secondsPerSlot: 12,
        slotsPerEpoch: 32
    )

    public static let gnosis = MyotisCheckpointNetwork(
        chainId: 100,
        network: "gnosis",
        source: "https://checkpoint.gnosischain.com",
        sources: [
            "https://checkpoint.gnosischain.com",
            "https://checkpoint-sync-gnosis.dappnode.net",
        ],
        participants: 2,
        threshold: 2,
        prover: "https://gnosis.colibri-proof.tech",
        genesis: 1_638_993_340,
        secondsPerSlot: 5,
        slotsPerEpoch: 16
    )

    public static let all: [MyotisCheckpointNetwork] = [.mainnet, .gnosis]

    /// Throws `.mismatch` for an unknown chain (desktop `networkFor`).
    public static func forChain(_ chainId: UInt64) throws -> MyotisCheckpointNetwork {
        guard let network = all.first(where: { $0.chainId == chainId }) else {
            throw MyotisCheckpointError.mismatch
        }
        return network
    }

    /// Wall-clock time of a slot, in ms since the epoch.
    public func slotTimeMs(_ slot: UInt64) -> Int64 {
        Int64(genesis + slot * secondsPerSlot) * 1000
    }

    /// The slot the wall clock is in right now (floor).
    public func wallSlot(nowMs: Int64) -> Int64 {
        let seconds = nowMs / 1000
        return (seconds - Int64(genesis)) / Int64(secondsPerSlot)
    }

    /// The epoch boundary a slot's finality certificate must reach.
    public func epochCeil(_ slot: UInt64) -> UInt64 {
        (slot + slotsPerEpoch - 1) / slotsPerEpoch
    }
}

/// Hex helpers shared by the quorum client, the store and the node.
public enum MyotisHex {
    /// `0x` + 64 lowercase hex, non-zero. Accepts an optional `0x`
    /// prefix and any case on input.
    public static func root(_ value: String?) -> String? {
        guard let value else { return nil }
        var hex = value
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex.removeFirst(2) }
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        let lower = hex.lowercased()
        guard lower.contains(where: { $0 != "0" }) else { return nil }
        return "0x" + lower
    }

    /// Any 32-byte hex (zero allowed) — proof branches.
    public static func bytes32(_ value: String?) -> String? {
        guard let value else { return nil }
        var hex = value
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex.removeFirst(2) }
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "0x" + hex.lowercased()
    }

    /// Unsigned integer from a JSON number or a decimal / `0x` string.
    public static func uint(_ value: Any?) -> UInt64? {
        switch value {
        case let n as UInt64: return n
        case let n as Int: return n >= 0 ? UInt64(n) : nil
        case let n as Int64: return n >= 0 ? UInt64(n) : nil
        case let n as Double:
            guard n >= 0, n.rounded() == n, n <= 9_007_199_254_740_991 else { return nil }
            return UInt64(n)
        case let n as NSNumber:
            return uint(n.doubleValue)
        case let s as String:
            if s.hasPrefix("0x") || s.hasPrefix("0X") {
                return UInt64(s.dropFirst(2), radix: 16)
            }
            return UInt64(s, radix: 10)
        default: return nil
        }
    }
}

/// The persisted checkpoint record — desktop schema v2. `verifiedAt` is
/// ms since the epoch. `sources` are the quorum members that endorsed
/// `root` at `slot`; provenance, not a trust claim about any one host.
public struct MyotisCheckpointRecord: Codable, Sendable, Equatable {
    public static let schemaVersion = 2
    public static let maxAgeMs: Int64 = 60 * 60 * 1000

    public var schemaVersion: Int
    public var chainId: UInt64
    public var network: String
    public var root: String
    public var slot: UInt64
    public var verifiedAt: Int64
    public var sources: [String]
    public var finalizedEpoch: UInt64

    public init(
        chainId: UInt64, network: String, root: String, slot: UInt64,
        verifiedAt: Int64, sources: [String], finalizedEpoch: UInt64
    ) {
        self.schemaVersion = Self.schemaVersion
        self.chainId = chainId
        self.network = network
        self.root = root
        self.slot = slot
        self.verifiedAt = verifiedAt
        self.sources = sources
        self.finalizedEpoch = finalizedEpoch
    }

    /// Desktop `validateCheckpoint`. `fresh` applies the acquisition-time
    /// rules (clock agreement + 1 h max age); a reloaded generation is
    /// validated with `fresh: false` because the engine re-judges saved
    /// state against its own weak-subjectivity bound.
    public func validated(
        chainId: UInt64, nowMs: Int64, fresh: Bool = true
    ) throws -> MyotisCheckpointRecord {
        let config = try MyotisCheckpointNetwork.forChain(chainId)
        let quorum = schemaVersion == Self.schemaVersion
            && sources.count >= config.threshold
            && sources.count <= config.participants
            && Set(sources).count == sources.count
            && sources.allSatisfy { config.sources.contains($0) }
        guard quorum,
              self.chainId == chainId,
              network == config.network,
              let root = MyotisHex.root(root), root == self.root,
              slot > 0,
              verifiedAt > 0
        else { throw MyotisCheckpointError.mismatch }
        let slotTime = config.slotTimeMs(slot)
        let (epochSlot, overflow) = finalizedEpoch.multipliedReportingOverflow(by: config.slotsPerEpoch)
        guard !overflow, epochSlot >= slot else { throw MyotisCheckpointError.mismatch }
        guard verifiedAt >= slotTime else { throw MyotisCheckpointError.mismatch }
        if fresh {
            let wallSlot = config.wallSlot(nowMs: nowMs)
            if slotTime > nowMs || Int64(epochSlot) > wallSlot || verifiedAt > nowMs {
                throw MyotisCheckpointError.clock
            }
            if nowMs - slotTime > Self.maxAgeMs { throw MyotisCheckpointError.stale }
        }
        var out = self
        out.schemaVersion = Self.schemaVersion
        out.network = config.network
        out.root = root
        return out
    }
}
