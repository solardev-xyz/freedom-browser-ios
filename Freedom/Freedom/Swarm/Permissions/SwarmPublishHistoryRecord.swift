import Foundation
import SwiftData

/// One `window.swarm` publish — recorded the moment the bridge accepts
/// the request, updated to `completed`/`failed` once bee replies. The
/// row sticks around after the publish settles so the user can later
/// re-find references they uploaded; no auto-retention.
///
/// Mirrors the desktop `publishes` SQLite table column-for-column so a
/// future cross-platform sync (or shared docs) doesn't need a vocabulary
/// translation. Desktop's autoincrement `id` becomes a UUID here — gives
/// the UI a stable selection key without leaking SwiftData's
/// `PersistentIdentifier` into view code.
@Model
final class SwarmPublishHistoryRecord {
    @Attribute(.unique) var id: UUID
    var kind: SwarmPublishKind
    /// `nil` when the dapp omits a name (raw `swarm_publishData` with
    /// no `name` field). UI falls back to a type-derived placeholder.
    var name: String?
    var status: SwarmPublishHistoryStatus
    /// 64-char hex Swarm reference (no `0x`). For `feed-entry` this is
    /// the SOC address (deterministic from topic+index+owner) rather
    /// than a manifest reference.
    var reference: String?
    /// Bee tag uid issued at upload time. Lets the detail view poll
    /// `swarm_getUploadStatus` for in-flight rows. `nil` for feed
    /// operations (no tag).
    var tagUid: Int?
    /// Postage batch id used for the upload — denormalized so the row
    /// remains useful after the batch expires and disappears from the
    /// stamp service.
    var batchId: String?
    /// Dapp URL that initiated the publish. Always populated — iOS has
    /// no in-app publish surface, every entry comes from `window.swarm`.
    var origin: String
    /// Payload size in bytes. `nil` for metadata-only operations
    /// (`feed-create`, `feed-update`).
    var bytesSize: Int?
    var startedAt: Date
    var completedAt: Date?
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        kind: SwarmPublishKind,
        name: String?,
        origin: String,
        bytesSize: Int? = nil,
        startedAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.status = .uploading
        self.reference = nil
        self.tagUid = nil
        self.batchId = nil
        self.origin = origin
        self.bytesSize = bytesSize
        self.startedAt = startedAt
        self.completedAt = nil
        self.errorMessage = nil
    }

    /// `bzz://{reference}` once the publish succeeds. Computed rather
    /// than stored — desktop persists it but it's a pure function of
    /// `reference`, and persisting both lets the two drift.
    var bzzUrl: String? {
        reference.map { "bzz://\($0)" }
    }
}

/// What was published. String-backed for SwiftData and to match the
/// desktop column values verbatim.
enum SwarmPublishKind: String, Codable, CaseIterable {
    case data = "data"
    case files = "files"
    case feedCreate = "feed-create"
    case feedUpdate = "feed-update"
    case feedEntry = "feed-entry"
}

enum SwarmPublishHistoryStatus: String, Codable, CaseIterable {
    case uploading
    case completed
    case failed
}
