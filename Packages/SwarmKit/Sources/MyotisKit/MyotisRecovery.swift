import Foundation

/// Stale-anchor recovery, part 4: the user-visible recovery state and
/// the policy tables behind it. Port of desktop `myotis-manager.js`'s
/// `recovery` object, reason mapping and retry ladder (PR #353). Pure
/// values; the state machine that drives them lives in `MyotisNode`.

/// Why recovery stopped or is waiting. Raw values match desktop's
/// reason strings so logs and docs line up.
public enum MyotisRecoveryReason: String, Sendable, Equatable, CaseIterable {
    case unavailable
    case quorumUnavailable = "quorum-unavailable"
    case quorumConflict = "quorum-conflict"
    case mismatch
    case clock
    case storage
    case storageIO = "storage-io"
    case ownership
    case stale
    case unsupported
    case installation
    case startup
    case stalled

    /// Desktop `reasons[error.code] || 'unavailable'`.
    public init(_ error: MyotisCheckpointError) {
        switch error {
        case .quorumUnavailable: self = .quorumUnavailable
        case .quorumConflict: self = .quorumConflict
        case .mismatch: self = .mismatch
        case .clock: self = .clock
        case .storage: self = .storage
        case .storageIO: self = .storageIO
        case .ownership: self = .ownership
        case .stale: self = .stale
        case .incompatible, .unsupported: self = .unsupported
        case .unavailable, .race: self = .unavailable
        }
    }

    /// Whether a manual "Retry sync" is offered when blocked.
    public var canRetry: Bool { self != .unsupported && self != .installation }

    /// Manual retry for these restarts the SAME owned generation (no new
    /// checkpoint needed): the engine's own stale guard re-requests one
    /// if the anchor really expired.
    public var restartsOwnedState: Bool {
        switch self {
        case .startup, .stalled, .storage, .storageIO, .ownership: true
        default: false
        }
    }

    /// The manual action is "Repair sync data" (fresh generation, old
    /// data preserved) rather than a plain retry.
    public var offersRepair: Bool { self == .storage }

    /// Reasons that come with a "Get help" explanation.
    public var offersHelp: Bool {
        switch self {
        case .storage, .storageIO, .ownership, .installation, .unsupported: true
        default: false
        }
    }

    /// One-line explanation shown in Nodes while blocked.
    public var explanation: String {
        switch self {
        case .unavailable: MyotisCheckpointError.unavailable.message
        case .quorumUnavailable: MyotisCheckpointError.quorumUnavailable.message
        case .quorumConflict: MyotisCheckpointError.quorumConflict.message
        case .mismatch: MyotisCheckpointError.mismatch.message
        case .clock: MyotisCheckpointError.clock.message
        case .storage: MyotisCheckpointError.storage.message
        case .storageIO: MyotisCheckpointError.storageIO.message
        case .ownership: MyotisCheckpointError.ownership.message
        case .stale: MyotisCheckpointError.stale.message
        case .unsupported: MyotisCheckpointError.unsupported.message
        case .installation: "The light client engine in this build could not be loaded. Update or reinstall Freedom."
        case .startup: "The light client could not start. Try again."
        case .stalled: "Sync has not finished in a while. Retry to restart the light client."
        }
    }

    /// Longer help for `offersHelp` reasons.
    public var help: String {
        switch self {
        case .storage:
            "The saved sync data does not match its record. Repair keeps the old data and starts a fresh verified sync. Nothing is deleted."
        case .storageIO:
            "Freedom could not read or write its sync data. Check that the device has free space and that Freedom is allowed to use storage, then retry."
        case .ownership:
            "The previous light client did not shut down cleanly and still owns its sync data. Fully quit and reopen Freedom, then retry."
        case .installation:
            "The embedded light client engine is missing or damaged. Update Freedom from the App Store or TestFlight, or reinstall it."
        case .unsupported:
            "This build cannot verify sync checkpoints. Update Freedom to a version with checkpoint recovery."
        default: explanation
        }
    }
}

/// Live recovery status for one chain. `nil` on the node means no
/// recovery is in progress or blocked.
public struct MyotisRecoveryState: Sendable, Equatable {
    public enum Phase: String, Sendable {
        /// Acquiring + verifying a checkpoint.
        case checking
        /// Checkpoint verified (or owned restart requested), engine restarting.
        case restarting
        /// Automatic retry scheduled (`nextRetryAt`).
        case waiting
        /// Automatic retries exhausted or a terminal failure; user action.
        case blocked
    }

    public enum Mode: String, Sendable {
        /// Recovery with a new verified checkpoint.
        case checkpoint
        /// Restart of the same owned generation (no new checkpoint).
        case restart
    }

    public var phase: Phase
    public var mode: Mode
    public var reason: MyotisRecoveryReason?
    public var attempt: Int
    public var nextRetryAt: Date?
    public var canRetry: Bool
    /// When the current recovery episode started — spans automatic
    /// retries; reset by a manual retry.
    public var startedAt: Date?

    public init(
        phase: Phase, mode: Mode = .checkpoint, reason: MyotisRecoveryReason? = nil,
        attempt: Int, nextRetryAt: Date? = nil, canRetry: Bool = false, startedAt: Date? = nil
    ) {
        self.phase = phase
        self.mode = mode
        self.reason = reason
        self.attempt = attempt
        self.nextRetryAt = nextRetryAt
        self.canRetry = canRetry
        self.startedAt = startedAt
    }

    /// Desktop `recovery.takingLonger`: the quiet progress notice after
    /// one minute of recovering. Spans the automatic retries (the episode
    /// started at `startedAt`), so a long outage reads "still trying"
    /// rather than looking stuck; cleared with the state on success.
    public func takingLonger(now: Date = Date()) -> Bool {
        guard let startedAt, phase != .blocked else { return false }
        return now.timeIntervalSince(startedAt) >= MyotisRecoveryPolicy.noticeSeconds
    }

    /// Manual retry is offered while blocked AND while waiting for an
    /// automatic retry (desktop PR #416): a user need not sit out a
    /// five-minute wait after an outage ends.
    public var offersRetry: Bool {
        canRetry && (phase == .blocked || phase == .waiting)
    }

    /// Desktop `myotis-ui.js` label + message for the chain row.
    public var label: String {
        switch phase {
        case .blocked: reason == .stalled ? "Syncing slowly" : "Sync paused"
        default: "Recovering"
        }
    }

    public func message(now: Date = Date()) -> String {
        switch phase {
        case .checking: return "Updating sync checkpoint…"
        case .restarting: return mode == .restart ? "Restarting node…" : "Checkpoint verified. Restarting sync…"
        case .waiting:
            let seconds = max(0, Int((nextRetryAt ?? now).timeIntervalSince(now).rounded(.up)))
            let why = reason?.explanation ?? MyotisRecoveryReason.unavailable.explanation
            return "\(why) Retrying in \(seconds)s…"
        case .blocked:
            return reason?.explanation ?? MyotisRecoveryReason.unavailable.explanation
        }
    }
}

/// The retry ladder and timers (desktop constants, PR #353 + #416).
public enum MyotisRecoveryPolicy {
    /// Automatic retry delays by attempt (attempt 1 fails → 15 s, attempt
    /// 2 fails → 60 s, every later failure → `backgroundRetrySeconds`).
    /// Transient outages (a checkpoint service down, a race, a stale
    /// reply) never park recovery permanently; only terminal reasons
    /// (conflict, mismatch, clock, storage, unsupported) block.
    public static let retryDelaysSeconds: [TimeInterval] = [15, 60]
    /// Desktop `RECOVERY_BACKGROUND_RETRY_MS`: the steady cadence after
    /// the ladder — patient enough not to hammer outages, frequent enough
    /// that a returning service is picked up without user action.
    public static let backgroundRetrySeconds: TimeInterval = 5 * 60
    /// "Taking longer than expected" after this long recovering.
    public static let noticeSeconds: TimeInterval = 60
    /// Not ready for this long with no recovery in flight → `stalled`.
    public static let stallSeconds: TimeInterval = 5 * 60

    /// Delay before the next automatic attempt for a retryable failure.
    /// Never nil for a real attempt: the ladder, then the background
    /// cadence. (nil only for a nonsensical attempt number.)
    public static func retryDelay(afterAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 1 else { return nil }
        guard attempt <= retryDelaysSeconds.count else { return backgroundRetrySeconds }
        return retryDelaysSeconds[attempt - 1]
    }

    /// Desktop `canFinishRecovery`: the engine has synced past the
    /// anchored checkpoint and, when it is still exactly at the
    /// checkpoint slot, the finalized root is the anchored root.
    public static func canFinish(status: MyotisChainStatus, checkpoint: MyotisCheckpointRecord?) -> Bool {
        guard status.beaconState == "SYNCED" else { return false }
        guard let checkpoint else { return true }
        guard status.finalizedSlot >= checkpoint.slot,
              let root = MyotisHex.bytes32(status.finalizedRootHex)
        else { return false }
        return status.finalizedSlot != checkpoint.slot || root == checkpoint.root
    }

    /// Desktop `observeSync`'s runtime anchor-mismatch guard: SYNCED at
    /// exactly the checkpoint slot with a different finalized root.
    public static func isAnchorMismatch(status: MyotisChainStatus, checkpoint: MyotisCheckpointRecord?) -> Bool {
        guard let checkpoint, status.beaconState == "SYNCED", status.finalizedSlot == checkpoint.slot,
              let root = MyotisHex.bytes32(status.finalizedRootHex)
        else { return false }
        return root != checkpoint.root
    }
}
