import Foundation

enum ENSTrustLevel {
    case verified
    case userConfigured
    case unverified
    case conflict

    var displayName: String {
        switch self {
        case .verified: "Verified"
        case .userConfigured: "User-configured"
        case .unverified: "Unverified"
        case .conflict: "Conflict"
        }
    }
}

/// Which resolution method produced the trust result. `.myotis`,
/// `.colibri` and `.quorum` can all yield `level == .verified` but with
/// materially different threat models — the renderer surfaces the
/// distinction in the trust popover so users understand whether trust
/// comes from this device's own P2P light client, a sync-committee
/// proof via a remote prover, or M-of-K RPC agreement.
enum ENSResolutionMethod: String, CaseIterable, Equatable {
    /// Embedded fully-P2P light client. Not user-selectable in the
    /// method picker: it is an always-first tier gated only on node
    /// availability; the picker chooses the fallback beneath it (see
    /// `selectableCases`).
    case myotis
    case colibri
    case quorum
    case userConfigured = "user-configured"

    /// The cases the ENS settings method picker offers.
    static var selectableCases: [ENSResolutionMethod] {
        allCases.filter { $0 != .myotis }
    }

    var displayName: String {
        switch self {
        case .myotis: "P2P Light Client"
        case .colibri: "Colibri"
        case .quorum: "Quorum"
        case .userConfigured: "Custom RPC"
        }
    }
}

struct ENSBlock: Hashable {
    let number: UInt64
    let hash: String
}

struct ENSTrust: Equatable {
    let level: ENSTrustLevel
    /// Which naming system produced this result (ENS vs the NameNFT-backed
    /// WNS/GNS). Defaulted so pre-.wei construction sites stay valid; the
    /// UI uses it to label trust with the right system name.
    var system: NameSystem = .ens
    let method: ENSResolutionMethod
    let block: ENSBlock
    let agreed: [String]
    let dissented: [String]
    let queried: [String]
    let k: Int
    let m: Int
}

/// Outcome of an address → primary-name reverse lookup. `.unverified`
/// carries the claimed name parsed out of UR's `ReverseAddressMismatch`
/// revert — the UI surfaces it with a warning so users see that an
/// address *claims* a primary name that doesn't forward-verify back.
enum ENSReverseResolution: Equatable, Sendable {
    case none
    case verified(name: String)
    case unverified(claimedName: String?)
}
