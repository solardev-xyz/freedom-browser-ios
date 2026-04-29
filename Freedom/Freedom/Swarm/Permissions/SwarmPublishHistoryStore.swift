import Foundation
import Observation
import OSLog
import SwiftData

private let log = Logger(subsystem: "com.browser.Freedom", category: "SwarmPublishHistoryStore")

/// Persistent log of every `window.swarm` publish. The bridge calls
/// `record(...)` before issuing the bee request and `complete(id:...)`
/// or `fail(id:...)` after — so a row exists for in-flight uploads and
/// the detail view can poll progress against `tagUid`.
///
/// Two-step writes are required (rather than a single post-success
/// insert) for crash recovery: any `uploading` row at app launch
/// represents a publish that didn't get a final-status update (process
/// killed, OS reaped the app, …). `sweepOrphans()` flips those to
/// `failed` on every cold start, mirroring desktop's behavior.
@MainActor
@Observable
final class SwarmPublishHistoryStore {
    @ObservationIgnored private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func entries() -> [SwarmPublishHistoryRecord] {
        let descriptor = FetchDescriptor<SwarmPublishHistoryRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func entry(id: UUID) -> SwarmPublishHistoryRecord? {
        let descriptor = FetchDescriptor<SwarmPublishHistoryRecord>(
            predicate: #Predicate { $0.id == id }
        )
        return try? context.fetch(descriptor).first
    }

    /// Inserts a new `uploading` row and returns it for the caller to
    /// hand back to `complete`/`fail`. Direct-row API (rather than a
    /// UUID round-trip) avoids a `FetchDescriptor` per finalize on every
    /// publish; safe because the store is `@MainActor` and the row
    /// reference never crosses actors.
    @discardableResult
    func record(
        kind: SwarmPublishKind,
        name: String?,
        origin: String,
        bytesSize: Int? = nil
    ) -> SwarmPublishHistoryRecord {
        let record = SwarmPublishHistoryRecord(
            kind: kind, name: name, origin: origin, bytesSize: bytesSize
        )
        context.insert(record)
        save()
        return record
    }

    /// Final-state success update. `reference` is the 64-char hex
    /// returned by bee (manifest reference for publishes / new manifest
    /// for `updateFeed` / SOC address for `writeFeedEntry`).
    func complete(
        _ row: SwarmPublishHistoryRecord,
        reference: String,
        tagUid: Int? = nil,
        batchId: String? = nil
    ) {
        row.status = .completed
        row.reference = reference
        row.tagUid = tagUid
        row.batchId = batchId
        row.completedAt = .now
        save()
    }

    func fail(_ row: SwarmPublishHistoryRecord, errorMessage: String) {
        row.status = .failed
        row.errorMessage = errorMessage
        row.completedAt = .now
        save()
    }

    /// Flips any `uploading` row to `failed` with a fixed message.
    /// Called once at app launch — surviving `uploading` rows mean the
    /// process died mid-publish and there's no in-memory state to
    /// resume from.
    ///
    /// Filters in Swift rather than via `#Predicate`: SwiftData rejects
    /// implicit-member access (`$0.status == .uploading`) and silently
    /// returns no matches when the enum value is hoisted to a local
    /// (`predicate: #Predicate { $0.status == uploading }`). The fetch
    /// is unbounded but only runs once per cold start.
    func sweepOrphans() {
        let orphans = entries().filter { $0.status == .uploading }
        guard !orphans.isEmpty else { return }
        for row in orphans {
            row.status = .failed
            row.errorMessage = "Interrupted by app exit"
            row.completedAt = .now
        }
        save()
    }

    func delete(id: UUID) {
        guard let row = entry(id: id) else { return }
        context.delete(row)
        save()
    }

    /// Bulk-delete via `context.delete(model:)` issues a single SQL
    /// `DELETE FROM` and autosaves; iterating + `save()` would do the
    /// same work in N round-trips.
    func clearAll() {
        do {
            try context.delete(model: SwarmPublishHistoryRecord.self)
        } catch {
            log.error("clearAll failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func save() { context.saveLogging("SwarmPublishHistoryStore", to: log) }
}
