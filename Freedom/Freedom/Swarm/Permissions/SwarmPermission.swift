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
    /// Messaging tier (SWIP messaging extension). Declaration-level
    /// defaults (not just init defaults) so SwiftData's lightweight
    /// migration can fill existing rows.
    var autoApproveMessaging: Bool = false
    /// Set when the user approves the messaging-tier grant. `nil` =
    /// no grant. Lives on this row (not `SwarmFeedIdentity`) because
    /// the SWIP ties messaging to the connection lifecycle: revoke
    /// deletes the row and MUST drop the messaging grant with it.
    var messagingGrantedAt: Date?

    init(origin: String, connectedAt: Date = .now) {
        self.origin = origin
        self.connectedAt = connectedAt
        self.lastUsedAt = connectedAt
        self.autoApprovePublish = false
        self.autoApproveFeeds = false
        self.autoApproveMessaging = false
        self.messagingGrantedAt = nil
    }
}
