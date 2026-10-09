import XCTest
@testable import Freedom

/// The Radicle node's on-device storage: one directory per repository.
final class RadicleStorageTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("radicle-storage-\(UUID().uuidString)", isDirectory: true)
        let pack = home.appendingPathComponent("storage/z4V1sjrXqjvFdnCUbxPFqd5p4DtH5/objects/pack", isDirectory: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try Data(count: 300_000).write(to: pack.appendingPathComponent("pack-1.pack"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent("storage/z3gqcJUoA1n9HaHKufZs5FCSGazv5", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("storage/zNotAnID", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("storage/.tmp", isDirectory: true), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testRepositoryDirectoryIsTheBareID() {
        XCTAssertEqual(
            RadicleStorage.directory(rid: "rad:z4V1sjrXqjvFdnCUbxPFqd5p4DtH5", home: home.path).lastPathComponent,
            "z4V1sjrXqjvFdnCUbxPFqd5p4DtH5"
        )
    }

    func testListsStoredRepositoriesOnly() {
        XCTAssertEqual(RadicleStorage.storedRepos(home: home.path), ["rad:z3gqcJUoA1n9HaHKufZs5FCSGazv5", "rad:z4V1sjrXqjvFdnCUbxPFqd5p4DtH5"], "invalid names are never listed")
    }

    func testSizeAndRemoval() async {
        let rid = "rad:z4V1sjrXqjvFdnCUbxPFqd5p4DtH5"
        let sizes = await RadicleStorage.sizes(of: [rid, "rad:zmissing"], home: home.path)
        XCTAssertGreaterThanOrEqual(sizes[rid] ?? 0, 300_000)
        XCTAssertEqual(sizes["rad:zmissing"], 0)
        let removed = await RadicleStorage.removeCopy(rid: rid, home: home.path)
        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: RadicleStorage.directory(rid: rid, home: home.path).path))
        let again = await RadicleStorage.removeCopy(rid: rid, home: home.path)
        XCTAssertTrue(again, "nothing left to remove is fine")
        let invalid = await RadicleStorage.removeCopy(rid: "zNotAnID", home: home.path)
        XCTAssertFalse(invalid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("storage/zNotAnID").path), "a non-ID directory is never deleted")
    }
}
