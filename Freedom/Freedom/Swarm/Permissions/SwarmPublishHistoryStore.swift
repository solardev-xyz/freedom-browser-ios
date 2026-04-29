import Foundation
import Observation
import OSLog
import SwiftData

private let log = Logger(subsystem: "com.browser.Freedom", category: "SwarmPublishHistoryStore")

/// Persistent log of every `window.swarm` publish. The bridge calls
/// `record(...)` before issuing the bee request and `complete(...)` or
/// `fail(...)` after — so a row exists for in-flight uploads and the
/// detail view can poll progress against `tagUid`.
///
/// Two-step writes are required (rather than a single post-success
/// insert) for crash recovery: any `uploading` row at app launch
/// represents a publish that didn't get a final-status update (process
/// killed, OS reaped the app, …). `sweepOrphans()` flips those to
/// `failed` on every cold start, mirroring desktop's behavior.
///
/// `entries` is a published mirror of the persisted rows so SwiftUI
/// views observe it directly. A `record()` from the bridge in tab A
/// propagates to a visible list in tab B without any manual refresh —
/// reading the rows through a method (rather than a tracked property)
/// would silently break that.
@MainActor
@Observable
final class SwarmPublishHistoryStore {
    @ObservationIgnored private let context: ModelContext
    private(set) var entries: [SwarmPublishHistoryRecord] = []

    init(context: ModelContext) {
        self.context = context
        refresh()
    }

    /// Convenience over the cached array; UUIDs are unique so first-match
    /// is correct. O(n) on a small N — fine until 10k+ rows.
    func entry(id: UUID) -> SwarmPublishHistoryRecord? {
        entries.first { $0.id == id }
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
        refresh()
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
        refresh()
    }

    func fail(_ row: SwarmPublishHistoryRecord, errorMessage: String) {
        row.status = .failed
        row.errorMessage = errorMessage
        row.completedAt = .now
        save()
        refresh()
    }

    /// Filters in Swift rather than via `#Predicate`: SwiftData rejects
    /// implicit-member access (`$0.status == .uploading`) and silently
    /// returns no matches when the enum is hoisted to a local. The
    /// fetch is unbounded but only runs once per cold start.
    func sweepOrphans() {
        let orphans = entries.filter { $0.status == .uploading }
        guard !orphans.isEmpty else { return }
        for row in orphans {
            row.status = .failed
            row.errorMessage = "Interrupted by app exit"
            row.completedAt = .now
        }
        save()
        refresh()
    }

    func delete(id: UUID) {
        guard let row = entry(id: id) else { return }
        context.delete(row)
        save()
        refresh()
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
        refresh()
    }

    private func refresh() {
        let descriptor = FetchDescriptor<SwarmPublishHistoryRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        entries = (try? context.fetch(descriptor)) ?? []
    }

    private func save() { context.saveLogging("SwarmPublishHistoryStore", to: log) }
}
