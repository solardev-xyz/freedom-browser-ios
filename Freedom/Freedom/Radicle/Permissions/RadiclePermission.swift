import Foundation
import SwiftData

/// One grant of dapp → Radicle-node access, keyed by the normalized
/// `OriginIdentity.key`. Separate model from `SwarmPermission` because
/// the surfaces sit at different trust tiers (Radicle exposes the user's
/// forge identity + disk/bandwidth commitments) and revoke independently.
///
/// Tiers mirror desktop's `{ node, signing }` model
/// (docs/radicle-provider-api.md in freedom-browser): the row itself is
/// the connection grant; `signingGrantedAt` marks the identity/COB-write
/// tier. Revoke deletes the row, which drops BOTH tiers — desktop parity.
@Model
final class RadiclePermission {
    @Attribute(.unique) var origin: String
    var connectedAt: Date
    var lastUsedAt: Date
    /// Signing tier: identity disclosure + COB writes as the user's one
    /// Radicle identity. One deliberate grant covers the tier (forge
    /// UX, like an OAuth scope) — no per-comment prompts.
    var signingGrantedAt: Date?
    /// Skip the per-repo seed sheet for this origin (`radicle_seed`).
    var autoApproveSeed: Bool

    init(origin: String, connectedAt: Date = .now) {
        self.origin = origin
        self.connectedAt = connectedAt
        self.lastUsedAt = connectedAt
        self.signingGrantedAt = nil
        self.autoApproveSeed = false
    }
}
