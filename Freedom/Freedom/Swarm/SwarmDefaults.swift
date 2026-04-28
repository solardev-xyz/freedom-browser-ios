import Foundation

extension Notification.Name {
    /// Posted when the user revokes a dapp's swarm grant.
    /// `userInfo["origin"]` carries the `OriginIdentity.key` so the
    /// bridge can match affected tabs and emit `disconnect`.
    static let swarmPermissionRevoked = Notification.Name("swarmPermissionRevoked")
}
