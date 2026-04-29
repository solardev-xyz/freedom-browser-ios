import Foundation
import Observation
import OSLog
import SwiftData

private let log = Logger(subsystem: "com.browser.Freedom", category: "SwarmFeedStore")

/// Manages `SwarmFeedRecord` (per-feed metadata) and `SwarmFeedIdentity`
/// (per-origin publisher identity). Both survive permission revocation
/// — re-granting an origin restores its prior feeds and signing key.
@MainActor
@Observable
final class SwarmFeedStore {
    @ObservationIgnored private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Feed records

    func lookup(origin: String, name: String) -> SwarmFeedRecord? {
        let descriptor = FetchDescriptor<SwarmFeedRecord>(
            predicate: #Predicate { $0.origin == origin && $0.name == name }
        )
        return try? context.fetch(descriptor).first
    }

    /// Oldest-first — matches the order the calling dapp's
    /// `swarm_createFeed` calls happened.
    func all(forOrigin origin: String) -> [SwarmFeedRecord] {
        let descriptor = FetchDescriptor<SwarmFeedRecord>(
            predicate: #Predicate { $0.origin == origin },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Idempotent. SWIP §"swarm_createFeed": creating a feed that
    /// already exists returns the existing metadata; this writer
    /// honors that — re-creating the same `(origin, name)` is a no-op.
    func upsert(
        origin: String, name: String,
        topic: String, owner: String, manifestReference: String
    ) {
        if lookup(origin: origin, name: name) != nil { return }
        let record = SwarmFeedRecord(
            origin: origin, name: name,
            topic: topic, owner: owner, manifestReference: manifestReference
        )
        context.insert(record)
        save()
    }

    /// Update the feed's mutable pointer after a `swarm_updateFeed`.
    /// No-op for unknown `(origin, name)` — caller already verified
    /// existence before issuing the bee write.
    func updateReference(origin: String, name: String, reference: String) {
        guard let record = lookup(origin: origin, name: name) else { return }
        record.lastReference = reference
        record.lastUpdatedAt = .now
        save()
    }

    // MARK: - Feed identity

    func feedIdentity(origin: String) -> SwarmFeedIdentity? {
        let descriptor = FetchDescriptor<SwarmFeedIdentity>(
            predicate: #Predicate { $0.origin == origin }
        )
        return try? context.fetch(descriptor).first
    }

    /// First-write-wins. SWIP §8.6 makes mode immutable — subsequent
    /// calls for the same origin are no-ops, even with different args.
    /// For `appScoped`, the publisher index is computed at insert
    /// time as `max(existing index) + 1` — keeping the allocation in
    /// the same transaction as the insert prevents two concurrent
    /// approval flows from different origins racing to the same
    /// index. Rows are never deleted, so max-derivation is stable.
    func setFeedIdentity(
        origin: String, identityMode: SwarmFeedIdentityMode
    ) {
        if feedIdentity(origin: origin) != nil { return }
        let identity = SwarmFeedIdentity(
            origin: origin,
            identityMode: identityMode,
            publisherKeyIndex: identityMode == .appScoped
                ? computeNextPublisherKeyIndex() : nil
        )
        context.insert(identity)
        save()
    }

    private func computeNextPublisherKeyIndex() -> Int {
        let descriptor = FetchDescriptor<SwarmFeedIdentity>()
        let rows = (try? context.fetch(descriptor)) ?? []
        let max = rows.compactMap(\.publisherKeyIndex).max() ?? -1
        return max + 1
    }

    private func save() {
        do {
            try context.save()
        } catch {
            log.error("SwarmFeedStore save failed: \(String(describing: error), privacy: .public)")
        }
    }
}
