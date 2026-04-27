import Foundation

/// Filesystem operations against Bee's data directory. Two distinct wipes
/// happen at different points in identity injection:
///
///   1. `wipeAuxiliaryState(at:)` — runs on every key swap. Removes only the
///      state tied to the *previous* identity (statestore, localstore,
///      kademlia-metrics, stamperstore, libp2p / pss keys). The keystore
///      `keys/swarm.key` stays — we overwrite it in the same injection step.
///      Without this wipe, Bee boots with a new overlay address but stale
///      routing/peer state and silently fails to gossip.
///
///   2. `wipeAll(at:)` — runs once on first launch after `BeePassword` lands,
///      to evict an install that was running with the legacy hardcoded
///      `"freedom-default"` password. The old keystore is unreadable with
///      the new random password; cleanest path is to start fresh.
///
/// Both are idempotent — paths that don't exist are silently skipped, so
/// re-runs after a partial failure work without special handling.
enum BeeStateDirs {
    /// Order is insignificant — paths are processed independently. Matches
    /// desktop `identity-manager.js:412-429`.
    static let auxiliaryRelativePaths: [String] = [
        "statestore",
        "localstore",
        "kademlia-metrics",
        "stamperstore",
        "keys/libp2p_v2.key",
        "keys/pss.key",
    ]

    /// Remove identity-tied auxiliary state. Leaves `keys/swarm.key`,
    /// `keys/swarm.key.bak`, `config.yaml`, and any other stable artifacts
    /// in place.
    static func wipeAuxiliaryState(at dataDir: URL) throws {
        for relative in auxiliaryRelativePaths {
            try removeIfExists(dataDir.appendingPathComponent(relative))
        }
    }

    /// Remove everything inside the data directory. Used on the first-launch
    /// migration where we can't tell what password the existing files were
    /// encrypted with — safer to start clean than to gamble.
    static func wipeAll(at dataDir: URL) throws {
        try removeIfExists(dataDir)
        try FileManager.default.createDirectory(
            at: dataDir, withIntermediateDirectories: true
        )
    }

    /// Idempotent: missing path → no-op, present → remove. The
    /// `fileExists` check is a TOCTOU race in theory, but the writers we
    /// race against (Bee, the user) shouldn't be touching a stopped node's
    /// data dir. Worst case: removeItem throws on the rare race; caller's
    /// retry handles it.
    private static func removeIfExists(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.removeItem(at: url)
    }
}
