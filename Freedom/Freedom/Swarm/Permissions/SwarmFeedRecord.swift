import Foundation
import SwiftData

/// One feed previously created via `swarm_createFeed`, keyed by
/// (`origin`, `name`).
///
/// `lastUpdatedAt` and `lastReference` are populated by
/// `swarm_updateFeed` only — null for journal-style feeds maintained
/// via `swarm_writeFeedEntry` (which writes payloads directly into
/// SOCs and never updates the manifest reference).
@Model
final class SwarmFeedRecord {
    var origin: String
    var name: String
    /// 64-char hex topic, no `0x` prefix — `keccak256(origin + "/" + name)`.
    var topic: String
    /// Checksummed `0x`-prefixed signer address. Matches desktop's
    /// `feed-store` shape so a cross-platform user sees the same value.
    var owner: String
    /// 64-char hex Swarm reference of the feed manifest (the stable
    /// `bzz://` root for the feed).
    var manifestReference: String
    var createdAt: Date
    var lastUpdatedAt: Date?
    var lastReference: String?

    init(
        origin: String,
        name: String,
        topic: String,
        owner: String,
        manifestReference: String,
        createdAt: Date = .now
    ) {
        self.origin = origin
        self.name = name
        self.topic = topic
        self.owner = owner
        self.manifestReference = manifestReference
        self.createdAt = createdAt
        self.lastUpdatedAt = nil
        self.lastReference = nil
    }

    /// SWIP `swarm_listFeeds` row shape — `Int` ms since epoch matching
    /// desktop's `Date.now()` output, `NSNull` for absent optionals so
    /// `JSONSerialization` round-trips them as JSON `null`.
    var asListFeedsRow: [String: Any] {
        [
            "name": name,
            "topic": topic,
            "owner": owner,
            "manifestReference": manifestReference,
            "bzzUrl": "bzz://\(manifestReference)",
            "createdAt": Int(createdAt.timeIntervalSince1970 * 1000),
            "lastUpdated": lastUpdatedAt.map { Int($0.timeIntervalSince1970 * 1000) } ?? NSNull() as Any,
            "lastReference": lastReference ?? NSNull() as Any,
        ]
    }
}
