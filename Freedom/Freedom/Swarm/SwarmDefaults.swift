import Foundation

enum SwarmDefaults {
    /// Gnosis RPC bee-lite uses in light mode and the fallback the
    /// `ant_storage_*` calls fall back to. Independent of
    /// `ChainRegistry`'s Gnosis pool (used for our own eth_calls) so
    /// either path can migrate without touching the other; ant's own
    /// chain reads go through the installed chain transport first.
    static let pinnedGnosisRPC = "https://rpc.gnosischain.com"
}

extension Notification.Name {
    /// Posted when the user revokes a dapp's swarm grant.
    /// `userInfo["origin"]` carries the `OriginIdentity.key` so the
    /// bridge can match affected tabs and emit `disconnect`.
    static let swarmPermissionRevoked = Notification.Name("swarmPermissionRevoked")
}
