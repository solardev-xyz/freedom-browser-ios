import Foundation
import OSLog
import SwarmKit

private let log = Logger(subsystem: "com.browser.Freedom", category: "SwarmCache")

/// The Swarm node's disk chunk cache on iPhone (desktop's Settings → Nodes
/// → Swarm cache, freedom-browser #579, over ant's C calls).
///
/// Since ant v0.5.62 the cache's SQLite connections map nothing (2 readers,
/// `mmap_size` 0, 8 MiB of page cache each), so the cap only bounds disk
/// use. Before that, each of 9 connections mapped up to 512 MiB of
/// `chunks.sqlite`, and a cache past 512 MiB exhausted the address space
/// iOS gives an app (the TestFlight crashes of 2026-10-08). Desktop offers
/// 512 MiB–16 GiB with a 2 GiB default; a phone has less space to spare.
enum SwarmCache {
    static let mib: UInt64 = 1 << 20
    static let gib: UInt64 = 1 << 30
    static let sizes: [UInt64] = [256 * mib, 512 * mib, 1 * gib, 2 * gib, 5 * gib]
    static let defaultBytes: UInt64 = 1 * gib

    /// A stored size that isn't offered (an older build's, a typo) falls
    /// back to the default, so ant only ever gets a known value.
    static func sanitized(_ stored: Int) -> UInt64 {
        let bytes = UInt64(max(0, stored))
        return sizes.contains(bytes) ? bytes : defaultBytes
    }

    static func label(_ bytes: UInt64) -> String {
        bytes >= gib ? "\(bytes / gib) GB" : "\(bytes / mib) MB"
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    /// "84 MB of 256 MB · 12 MB pinned", the pinned part only when there is some.
    static func summary(_ status: SwarmCacheStatus) -> String {
        let used = "\(format(status.usedBytes)) of \(format(status.capacityBytes))"
        return status.pinnedBytes > 0 ? "\(used) · \(format(status.pinnedBytes)) pinned" : used
    }

    // MARK: - Oversized caches from earlier builds

    /// A cache file far past its cap: earlier builds let it grow to ant's
    /// old default, and lowering the cap evicts chunks without shrinking a
    /// file created by an older ant. Only a clear rebuilds it smaller. With
    /// ant's v0.5.62 tuning it no longer threatens the address space; this
    /// only gives the disk space back.
    static func needsShrink(_ status: SwarmCacheStatus) -> Bool {
        status.diskEnabled && status.fileBytes > max(2 * status.capacityBytes, 512 * mib)
    }

    static let shrinkDoneKey = "swarm.cache.shrinkDone.v1"

    /// Once per install: clear an oversized cache so its file shrinks back
    /// under the address-space budget. Only unpinned cached chunks go;
    /// pinned and published content stays. Marked done whatever the
    /// outcome, so a cache ant can't shrink isn't wiped at every launch.
    static func shrinkOversizedOnce(swarm: SwarmNode, defaults: UserDefaults = .standard) async {
        guard !defaults.bool(forKey: shrinkDoneKey), let status = await swarm.cacheStatus() else { return }
        guard needsShrink(status) else {
            defaults.set(true, forKey: shrinkDoneKey)
            return
        }
        defaults.set(true, forKey: shrinkDoneKey)
        do {
            let result = try await swarm.clearCache()
            log.info("[swarm-cache] oversized cache cleared: file \(result.fileBytesBefore) → \(result.fileBytesAfter) bytes")
        } catch {
            log.warning("[swarm-cache] oversized cache not cleared: \(error.localizedDescription, privacy: .public)")
        }
    }
}
