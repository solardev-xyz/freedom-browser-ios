import Foundation
import SwiftData

/// One grant of dapp → swarm-publishing access, keyed by the normalized
/// `OriginIdentity.key`. Separate model from `DappPermission` because the
/// two surfaces sit at different trust tiers (wallet exposes account
/// signatures; swarm exposes node bandwidth + storage) and persist
/// independently. Feed identity (mode + per-origin publisher key index)
/// lives on `SwarmFeedIdentity` instead — that survives revocation; this
/// row doesn't.
@Model
final class SwarmPermission {
    @Attribute(.unique) var origin: String
    var connectedAt: Date
    var lastUsedAt: Date
    var autoApprovePublish: Bool
    var autoApproveFeeds: Bool

    init(origin: String, connectedAt: Date = .now) {
        self.origin = origin
        self.connectedAt = connectedAt
        self.lastUsedAt = connectedAt
        self.autoApprovePublish = false
        self.autoApproveFeeds = false
    }
}
