import Foundation
import SwiftData

/// One grant of dapp → swarm-publishing access, keyed by the normalized
/// `OriginIdentity.key`. Separate model from `DappPermission` because the
/// two surfaces sit at different trust tiers (wallet exposes account
/// signatures; swarm exposes node bandwidth + storage) and persist
/// independently.
@Model
final class SwarmPermission {
    @Attribute(.unique) var origin: String
    var connectedAt: Date
    var lastUsedAt: Date
    var autoApprovePublish: Bool
    var autoApproveFeeds: Bool
    /// `"app-scoped"` or `"bee-wallet"`. Picked at the first feed grant
    /// and immutable thereafter — flipping it would orphan existing
    /// feeds (the topic + signing key are derived from this choice).
    var identityMode: String

    init(origin: String, connectedAt: Date = .now) {
        self.origin = origin
        self.connectedAt = connectedAt
        self.lastUsedAt = connectedAt
        self.autoApprovePublish = false
        self.autoApproveFeeds = false
        self.identityMode = "app-scoped"
    }
}
