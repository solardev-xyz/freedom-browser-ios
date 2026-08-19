import Foundation
import Observation
import OSLog
import SwiftData

private let log = Logger(subsystem: "com.browser.Freedom", category: "RadiclePermissionStore")

extension Notification.Name {
    /// Posted by `revoke` with the origin key in `userInfo["origin"]`;
    /// the bridge subscribes and emits a JS-side `disconnect` event to
    /// any tab whose origin matches — same contract as
    /// `.swarmPermissionRevoked`.
    static let radiclePermissionRevoked = Notification.Name("radiclePermissionRevoked")
}

/// Persisted Radicle grants. Mirrors `SwarmPermissionStore` in shape —
/// `isConnected` sits on the bridge's hot path, so reads come from an
/// in-memory `Set<String>`; writes go through SwiftData and keep the set
/// in sync.
@MainActor
@Observable
final class RadiclePermissionStore {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var connectedOrigins: Set<String>

    init(context: ModelContext) {
        self.context = context
        let descriptor = FetchDescriptor<RadiclePermission>()
        let fetched = (try? context.fetch(descriptor)) ?? []
        self.connectedOrigins = Set(fetched.map(\.origin))
    }

    func grant(origin: String) {
        if let existing = fetch(origin: origin) {
            existing.lastUsedAt = .now
        } else {
            context.insert(RadiclePermission(origin: origin))
        }
        connectedOrigins.insert(origin)
        save()
    }

    /// Drops the connection AND signing tiers plus auto-approvals — the
    /// row is the grant (desktop's `radicle_disconnect` semantics).
    func revoke(origin: String) {
        guard let existing = fetch(origin: origin) else { return }
        context.delete(existing)
        connectedOrigins.remove(origin)
        save()
        NotificationCenter.default.post(
            name: .radiclePermissionRevoked,
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

    func hasSigningGrant(_ origin: String) -> Bool {
        fetch(origin: origin)?.signingGrantedAt != nil
    }

    /// No-op without a connection row — signing requires the base
    /// connection grant first (`radicle_requestAccess`).
    func grantSigning(origin: String) {
        guard let permission = fetch(origin: origin) else { return }
        guard permission.signingGrantedAt == nil else { return }
        permission.signingGrantedAt = .now
        save()
    }

    func isAutoApproveSeed(origin: String) -> Bool {
        fetch(origin: origin)?.autoApproveSeed ?? false
    }

    func setAutoApproveSeed(origin: String, enabled: Bool) {
        guard let permission = fetch(origin: origin) else { return }
        guard permission.autoApproveSeed != enabled else { return }
        permission.autoApproveSeed = enabled
        save()
    }

    private func fetch(origin: String) -> RadiclePermission? {
        let descriptor = FetchDescriptor<RadiclePermission>(
            predicate: #Predicate { $0.origin == origin }
        )
        return try? context.fetch(descriptor).first
    }

    private func save() { context.saveLogging("RadiclePermission", to: log) }
}
