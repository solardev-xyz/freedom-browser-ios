import Foundation
import Observation
import OSLog
import SwiftData

private let log = Logger(subsystem: "com.browser.Freedom", category: "SwarmPermissionStore")

/// Persisted swarm-connection grants. Mirrors `PermissionStore` (wallet)
/// in shape — every router/bridge call hits `isConnected` on the hot
/// path, so reads come from an in-memory `Set<String>`, writes go through
/// SwiftData and keep the set in sync.
///
/// Revoke posts `.swarmPermissionRevoked` with the origin key in
/// `userInfo["origin"]`; WP4's bridge subscribes and emits a JS-side
/// `disconnect` event to any tab whose origin matches.
@MainActor
@Observable
final class SwarmPermissionStore {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var connectedOrigins: Set<String>

    init(context: ModelContext) {
        self.context = context
        let descriptor = FetchDescriptor<SwarmPermission>()
        let fetched = (try? context.fetch(descriptor)) ?? []
        self.connectedOrigins = Set(fetched.map(\.origin))
    }

    /// An existing row keeps its auto-approve flags and identity mode;
    /// `revoke` (which deletes the row) is the only path that resets
    /// them. Re-granting after revoke therefore starts fresh.
    func grant(origin: String) {
        if let existing = fetch(origin: origin) {
            existing.lastUsedAt = .now
        } else {
            context.insert(SwarmPermission(origin: origin))
        }
        connectedOrigins.insert(origin)
        save()
    }

    func revoke(origin: String) {
        guard let existing = fetch(origin: origin) else { return }
        context.delete(existing)
        connectedOrigins.remove(origin)
        save()
        NotificationCenter.default.post(
            name: .swarmPermissionRevoked,
            object: nil,
            userInfo: ["origin": origin]
        )
    }

    func isConnected(_ origin: String) -> Bool {
        connectedOrigins.contains(origin)
    }

    func touchLastUsed(origin: String) {
        guard let permission = fetch(origin: origin) else { return }
        permission.lastUsedAt = .now
        save()
    }

    /// Read by the bridge before parking a `swarm_publishData` /
    /// `swarm_publishFiles` approval — `true` skips the sheet. Single
    /// SwiftData fetch per publish call; not cached because publish
    /// frequency is bounded by user clicks.
    func isAutoApprovePublish(origin: String) -> Bool {
        fetch(origin: origin)?.autoApprovePublish ?? false
    }

    /// Set by the publish sheet's auto-approve toggle when the user
    /// approves with the toggle on. No-op if the origin has no grant
    /// yet — auto-approve only meaningful for connected origins.
    func setAutoApprovePublish(origin: String, enabled: Bool) {
        guard let permission = fetch(origin: origin) else { return }
        guard permission.autoApprovePublish != enabled else { return }
        permission.autoApprovePublish = enabled
        save()
    }

    private func fetch(origin: String) -> SwarmPermission? {
        let descriptor = FetchDescriptor<SwarmPermission>(
            predicate: #Predicate { $0.origin == origin }
        )
        return try? context.fetch(descriptor).first
    }

    private func save() {
        do {
            try context.save()
        } catch {
            log.error("SwarmPermission save failed: \(String(describing: error), privacy: .public)")
        }
    }
}
