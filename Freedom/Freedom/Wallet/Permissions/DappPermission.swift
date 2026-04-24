import Foundation
import SwiftData

/// One grant of dapp → wallet access, keyed by the normalized
/// `OriginIdentity.key`. `account` is the Ethereum address the user
/// authorized for this origin.
@Model
final class DappPermission {
    @Attribute(.unique) var origin: String
    var account: String
    var grantedAt: Date
    var lastUsedAt: Date

    init(origin: String, account: String, grantedAt: Date = .now) {
        self.origin = origin
        self.account = account
        self.grantedAt = grantedAt
        self.lastUsedAt = grantedAt
    }
}
