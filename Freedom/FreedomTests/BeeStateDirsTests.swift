import XCTest
@testable import Freedom

/// `BeeStateDirs` is the tiny filesystem helper that evicts identity-tied
/// state on key swap and the legacy data dir on first-launch migration.
/// Tests run against a fresh tmp dir per test — no real Bee data dir.
final class BeeStateDirsTests: XCTestCase {
    private var tmpDir: URL!
    private let fm = FileManager.default

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    // MARK: - wipeAuxiliaryState

    func testAuxiliaryWipeRemovesAllListedPaths() throws {
        try populateAuxiliaryState()
        try BeeStateDirs.wipeAuxiliaryState(at: tmpDir)
        for path in BeeStateDirs.auxiliaryRelativePaths {
            XCTAssertFalse(
                fm.fileExists(atPath: tmpDir.appendingPathComponent(path).path),
                "expected \(path) to be removed"
            )
        }
    }

    /// The keystore (`keys/swarm.key`) and any unrelated config file must
    /// survive an auxiliary wipe — we'll overwrite the keystore in a
    /// separate step, and Bee's config.yaml is identity-agnostic.
    func testAuxiliaryWipePreservesKeystoreAndConfig() throws {
        try populateAuxiliaryState()
        let keystore = tmpDir.appendingPathComponent("keys/swarm.key")
        let config = tmpDir.appendingPathComponent("config.yaml")
        try Data("keystore body".utf8).write(to: keystore)
        try Data("password: foo\n".utf8).write(to: config)

        try BeeStateDirs.wipeAuxiliaryState(at: tmpDir)

        XCTAssertTrue(fm.fileExists(atPath: keystore.path))
        XCTAssertTrue(fm.fileExists(atPath: config.path))
    }

    /// Idempotency property — running the wipe a second time on an
    /// already-wiped dir must not throw. Recovery from a partial failure
    /// in `BeeIdentityInjector` relies on this.
    func testAuxiliaryWipeIsIdempotent() throws {
        try populateAuxiliaryState()
        try BeeStateDirs.wipeAuxiliaryState(at: tmpDir)
        XCTAssertNoThrow(try BeeStateDirs.wipeAuxiliaryState(at: tmpDir))
    }

    /// No-op on an empty data dir — same idempotency contract, different
    /// starting state. Catches regressions where we'd accidentally throw
    /// on `removeItem` for a missing path.
    func testAuxiliaryWipeOnEmptyDirIsNoOp() throws {
        XCTAssertNoThrow(try BeeStateDirs.wipeAuxiliaryState(at: tmpDir))
    }

    // MARK: - wipeAll

    func testWipeAllClearsEverything() throws {
        try populateAuxiliaryState()
        try Data("keystore".utf8).write(to: tmpDir.appendingPathComponent("keys/swarm.key"))
        try Data("config".utf8).write(to: tmpDir.appendingPathComponent("config.yaml"))

        try BeeStateDirs.wipeAll(at: tmpDir)

        // Directory itself recreated empty.
        XCTAssertTrue(fm.fileExists(atPath: tmpDir.path))
        let contents = try fm.contentsOfDirectory(atPath: tmpDir.path)
        XCTAssertTrue(contents.isEmpty)
    }

    func testWipeAllIsIdempotent() throws {
        try BeeStateDirs.wipeAll(at: tmpDir)
        XCTAssertNoThrow(try BeeStateDirs.wipeAll(at: tmpDir))
    }

    func testWipeAllRecreatesMissingDir() throws {
        try fm.removeItem(at: tmpDir)
        XCTAssertFalse(fm.fileExists(atPath: tmpDir.path))
        try BeeStateDirs.wipeAll(at: tmpDir)
        XCTAssertTrue(fm.fileExists(atPath: tmpDir.path))
    }

    // MARK: - Helpers

    /// Create a representative subset of the aux state Bee writes, including
    /// nested files inside `statestore/` and `keys/`, so the wipe has to do
    /// real recursive removal — not just unlink top-level entries.
    private func populateAuxiliaryState() throws {
        for path in BeeStateDirs.auxiliaryRelativePaths {
            let url = tmpDir.appendingPathComponent(path)
            if path.hasSuffix(".key") {
                try fm.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("key body".utf8).write(to: url)
            } else {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                try Data("inner".utf8).write(
                    to: url.appendingPathComponent("nested.bin")
                )
            }
        }
    }
}
