import XCTest
@testable import Freedom

/// Old compiled rule lists are removed, and newer bundled lists win over an
/// older downloaded update (Florian's phone kept running August's v99 with
/// v148 bundled, and kept v99's and an old layout's compiles forever).
@MainActor
final class AdblockStaleListsTests: XCTestCase {
    private let bundledStems: Set<String> = ["easylist-1", "easylist-generic", "ublock", "ublock-generic"]

    func testOldVersionsAndOldLayoutGo() {
        let ids = [
            "freedom-adblock.v99.easylist-1", "freedom-adblock.v148.easylist-1", "freedom-adblock.v149.easylist-1",
            "freedom-adblock.easylist-1", "freedom-adblock.easylist-5", "freedom-adblock.easylist-annoyances-3",
            "freedom-adblock.ublock-generic", "someone-else.easylist-1",
        ]
        let dir = URL(fileURLWithPath: "/tmp/updated")
        let stale = AdblockService.staleIdentifiers(ids, active: .updated(feedVersion: 148, dir: dir), appliedVersion: 148, bundledStems: bundledStems)
        XCTAssertEqual(stale, ["freedom-adblock.v99.easylist-1", "freedom-adblock.easylist-5", "freedom-adblock.easylist-annoyances-3"])
    }

    /// Running the newer bundled lists over an older applied update: the
    /// update's compiles are stale, an update being staged right now isn't.
    func testBundledActiveDropsTheOlderUpdateButNotAStagedOne() {
        let ids = ["freedom-adblock.v99.easylist-1", "freedom-adblock.v148.easylist-1", "freedom-adblock.easylist-1"]
        let stale = AdblockService.staleIdentifiers(ids, active: .bundled, appliedVersion: 99, bundledStems: bundledStems)
        XCTAssertEqual(stale, ["freedom-adblock.v99.easylist-1"])
    }

    // MARK: - Boot source

    private func appliedUpdate(generatedAt: String, version: Int = 99) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adblock-boot-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("updated", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"feed_version":\#(version)}"#.utf8).write(to: dir.appendingPathComponent("state.json"))
        try Data(#"{"generated_at":"\#(generatedAt)"}"#.utf8).write(to: dir.appendingPathComponent("metadata.json"))
        return root
    }

    func testNewerBundledListsWinOverAnOlderUpdate() throws {
        let root = try appliedUpdate(generatedAt: "2026-08-25T20:10:00.000Z")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(AdblockUpdateService.currentSource(rootDir: root, bundledGeneratedAt: "2026-10-05T09:34:31.852Z"), .bundled)
    }

    func testAnUpdateAtLeastAsNewAsTheBundleStays() throws {
        let root = try appliedUpdate(generatedAt: "2026-10-05T09:34:31.852Z", version: 148)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("updated", isDirectory: true)
        XCTAssertEqual(AdblockUpdateService.currentSource(rootDir: root, bundledGeneratedAt: "2026-10-05T09:34:31.852Z"), .updated(feedVersion: 148, dir: dir))
        XCTAssertEqual(AdblockUpdateService.currentSource(rootDir: root, bundledGeneratedAt: "2026-09-01T00:00:00Z"), .updated(feedVersion: 148, dir: dir))
        XCTAssertEqual(AdblockUpdateService.currentSource(rootDir: root, bundledGeneratedAt: nil), .updated(feedVersion: 148, dir: dir), "unknown bundle date: keep the update")
    }
}
