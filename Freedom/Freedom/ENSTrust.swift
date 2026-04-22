import Foundation

enum ENSTrustLevel {
    case verified
    case userConfigured
    case unverified
    case conflict
}

struct ENSBlock: Hashable {
    let number: UInt64
    let hash: String
}

struct ENSTrust {
    let level: ENSTrustLevel
    let block: ENSBlock
    let agreed: [String]
    let dissented: [String]
    let queried: [String]
    let k: Int
    let m: Int
}
