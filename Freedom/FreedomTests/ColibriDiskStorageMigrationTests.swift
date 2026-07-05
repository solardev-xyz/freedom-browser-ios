import XCTest
import Colibri
@testable import Freedom

/// `ColibriDiskStorage.register` must wipe version-coupled verifier state
/// once per storage-format bump: 1.1.30 fails light-client catch-up over
/// 1.1.26-era sync-committee files ("invalid merkle root for finalized
/// header"), which silently degrades every Colibri resolution to the
/// quorum fallback. No network — pure filesystem behavior.
@MainActor
final class ColibriDiskStorageMigrationTests: XCTestCase {
    private var dir: URL!
    private let markerName = "freedom-colibri-storage-version"

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("colibri-migration-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        StorageBridge.implementation = nil
        if let dir { try? FileManager.default.removeItem(at: dir) }
        try await super.tearDown()
    }

    private func seedStaleState() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0xaa, count: 64)
            .write(to: dir.appendingPathComponent("sync_1_1784"))
        try Data(repeating: 0xbb, count: 16)
            .write(to: dir.appendingPathComponent("states_1"))
    }

    private var markerURL: URL { dir.appendingPathComponent(markerName) }

    func testUnmarkedStateIsWipedAndMarkerWritten() throws {
        // Pre-marker installs (≤ 1.1.26) have state files but no marker.
        try seedStaleState()
        ColibriDiskStorage.register(directory: dir)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("sync_1_1784").path),
            "stale sync-committee state must be wiped"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testMatchingMarkerPreservesState() throws {
        try seedStaleState()
        let version = "1.1.30"
        try version.write(to: markerURL, atomically: true, encoding: .utf8)
        ColibriDiskStorage.register(directory: dir)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("sync_1_1784").path),
            "state under the current format must survive registration"
        )
    }

    func testMismatchedMarkerWipes() throws {
        try seedStaleState()
        try "0.0.1".write(to: markerURL, atomically: true, encoding: .utf8)
        ColibriDiskStorage.register(directory: dir)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("sync_1_1784").path)
        )
        XCTAssertEqual(try String(contentsOf: markerURL, encoding: .utf8), "1.1.30")
    }

    func testFreshDirectoryJustGetsMarker() throws {
        ColibriDiskStorage.register(directory: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        // Storage must be writable after registration.
        let probe = dir.appendingPathComponent("states_1")
        XCTAssertNoThrow(try Data([0x01]).write(to: probe))
    }
}
