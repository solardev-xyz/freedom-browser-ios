import Foundation

/// In-memory `tagUid → origin` map for `swarm_getUploadStatus`'s
/// cross-origin-snooping defense (SWIP §"Security: Implementations
/// MUST enforce origin-scoped tag ownership"). Recorded on successful
/// `swarm_publishData` / `swarm_publishFiles`; the bridge consults it
/// before forwarding any `swarm_getUploadStatus` to bee.
///
/// Session-scoped — no SwiftData. Bee may evict its own tags too
/// (SWIP §"Persistence: Upload status for tags created in a previous
/// browser session MAY be unavailable"), so dropping ours on app
/// restart matches what the dapp would see anyway.
@MainActor
final class TagOwnership {
    private var ownerByTag: [Int: String] = [:]

    /// Last-write-wins on duplicate `tag` — bee tag UIDs are unique
    /// per session in practice, so a re-record overwriting an entry
    /// would only happen if bee recycled UIDs after a restart we
    /// didn't observe.
    func record(tag: Int, origin: String) {
        ownerByTag[tag] = origin
    }

    func owner(of tag: Int) -> String? {
        ownerByTag[tag]
    }

    /// Drops a tag — called on `done == true` reads or on bee 404 so
    /// the map doesn't grow without bound across a session.
    func forget(tag: Int) {
        ownerByTag.removeValue(forKey: tag)
    }
}
