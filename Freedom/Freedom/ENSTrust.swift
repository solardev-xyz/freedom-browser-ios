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

struct ENSBlock: Hashable {
    let number: UInt64
    let hash: String
}

struct ENSTrust: Equatable {
    let level: ENSTrustLevel
    let block: ENSBlock
    let agreed: [String]
    let dissented: [String]
    let queried: [String]
    let k: Int
    let m: Int
}
