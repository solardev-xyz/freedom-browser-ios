import XCTest
@testable import Freedom

/// The pieces of private tabs that are pure: an ephemeral permission
/// store, downloads left out of the index.
@MainActor
final class PrivateTabTests: XCTestCase {
    private var keep: [AnyObject] = []

    func testEphemeralPermissionStoreNeverTouchesDefaults() {
        let defaults = UserDefaults(suiteName: "PrivateTabTests-\(UUID().uuidString)")!
        let profile = SitePermissionStore(defaults: defaults); keep.append(profile)
        let ephemeral = SitePermissionStore(ephemeral: true); keep.append(ephemeral)
        XCTAssertTrue(ephemeral.isEphemeral)
        XCTAssertFalse(profile.isEphemeral)
        ephemeral.remember(origin: "https://a.example", kinds: [.camera], decision: .allow)
        XCTAssertEqual(ephemeral.settled(origin: "https://a.example", kinds: [.camera]), .allow, "remembered for its own lifetime")
        XCTAssertNil(profile.settled(origin: "https://a.example", kinds: [.camera]), "never reaches the profile")
        let reloaded = SitePermissionStore(defaults: defaults); keep.append(reloaded)
        XCTAssertTrue(reloaded.origins.isEmpty)
    }

    func testEphemeralDownloadsAreNotIndexed() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateTabTests-\(UUID().uuidString)")
        let first = DownloadManager(directory: dir); keep.append(first)
        first.seedForTesting(DownloadItem(id: UUID(), sourceURL: "https://x.example/a", filename: "a", mimeType: nil,
                                          bytesReceived: 1, totalBytes: 1, state: .completed, startedAt: Date(), finishedAt: Date(),
                                          ephemeral: true))
        first.seedForTesting(DownloadItem(id: UUID(), sourceURL: "https://x.example/b", filename: "b", mimeType: nil,
                                          bytesReceived: 1, totalBytes: 1, state: .completed, startedAt: Date(), finishedAt: Date()))
        XCTAssertEqual(first.items.count, 2, "visible while the app runs")
        let second = DownloadManager(directory: dir); keep.append(second)
        XCTAssertEqual(second.items.map(\.filename), ["b"], "the private one is gone at the next launch")
    }

    func testPrivateRecordsDefaultToNormal() {
        XCTAssertFalse(TabRecord().isPrivate)
        XCTAssertTrue(TabRecord(isPrivate: true).isPrivate)
    }
}
