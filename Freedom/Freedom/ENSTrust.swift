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

/// Which resolution method produced the trust result. `.colibri` and
/// `.quorum` can both yield `level == .verified` but with materially
/// different threat models — the renderer surfaces the distinction in
/// the trust popover so users understand whether trust comes from a
/// sync-committee proof or from M-of-K RPC agreement.
enum ENSResolutionMethod: String, CaseIterable, Equatable {
    case colibri
    case quorum
    case userConfigured = "user-configured"

    var displayName: String {
        switch self {
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
    let method: ENSResolutionMethod
    let block: ENSBlock
    let agreed: [String]
    let dissented: [String]
    let queried: [String]
    let k: Int
    let m: Int
}
