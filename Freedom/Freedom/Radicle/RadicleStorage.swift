import Foundation
import OSLog
import RadicleKit

private let log = Logger(subsystem: "com.browser.Freedom", category: "RadicleStorage")

/// What the embedded Radicle node keeps on this device: one git
/// repository per seeded project under `<home>/storage/<rid>`, each with
/// its full history (and growing with it). Sizes are measured from disk;
/// libradicle reports none.
enum RadicleStorage {
    /// `rad:z4V1…` → `<home>/storage/z4V1…`.
    static func directory(rid: String, home: String = RadicleNode.defaultHome()) -> URL {
        let bare = rid.hasPrefix("rad:") ? String(rid.dropFirst(4)) : rid
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent(bare, isDirectory: true)
    }

    /// Every repository directory in storage, keyed `rad:<id>`. Only names
    /// that are valid repository IDs (heartwood refuses to start on any
    /// other directory there, and this never lists or deletes one).
    static func storedRepos(home: String = RadicleNode.defaultHome()) -> [String] {
        let storage = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("storage", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: storage.path)) ?? []
        return names.compactMap { RadicleBridge.validateAndNormalizeRid($0) }.sorted()
    }

    /// Bytes on disk under `url` (allocated size), 0 when it's missing.
    static func size(of url: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Sizes for `rids`, measured off the main actor (a repository can be
    /// tens of thousands of files).
    static func sizes(of rids: [String], home: String = RadicleNode.defaultHome()) async -> [String: UInt64] {
        await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: rids.map { ($0, size(of: directory(rid: $0, home: home))) })
        }.value
    }

    /// Delete the local copy, as heartwood's `Repository::remove` does
    /// (`remove_dir_all` of the repository's directory). Call it after
    /// unseeding, so the node doesn't fetch it again.
    static func removeCopy(rid: String, home: String = RadicleNode.defaultHome()) async -> Bool {
        guard let rid = RadicleBridge.validateAndNormalizeRid(rid) else { return false }
        let url = directory(rid: rid, home: home)
        return await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else { return true }
            do {
                try FileManager.default.removeItem(at: url)
                return true
            } catch {
                log.warning("removing \(rid, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }.value
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
