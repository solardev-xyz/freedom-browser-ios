import SwiftData
import XCTest
@testable import Freedom

@MainActor
final class SwarmPermissionStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var store: SwarmPermissionStore!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: SwarmPermission.self, configurations: config)
        store = SwarmPermissionStore(context: container.mainContext)
    }

    func testGrantThenIsConnected() {
        XCTAssertFalse(store.isConnected("foo.eth"))
        store.grant(origin: "foo.eth")
        XCTAssertTrue(store.isConnected("foo.eth"))
    }

    func testGrantTwiceIsIdempotent() {
        store.grant(origin: "foo.eth")
        store.grant(origin: "foo.eth")
        XCTAssertTrue(store.isConnected("foo.eth"))
        // No duplicate row — the unique constraint would have thrown on save.
        let descriptor = FetchDescriptor<SwarmPermission>()
        let rows = (try? container.mainContext.fetch(descriptor)) ?? []
        XCTAssertEqual(rows.count, 1)
    }

    func testRevokeDropsGrantAndPostsNotification() {
        store.grant(origin: "foo.eth")
        let exp = expectation(forNotification: .swarmPermissionRevoked, object: nil) { n in
            (n.userInfo?["origin"] as? String) == "foo.eth"
        }
        store.revoke(origin: "foo.eth")
        wait(for: [exp], timeout: 1.0)
        XCTAssertFalse(store.isConnected("foo.eth"))
    }

    func testRevokeOfUnknownOriginIsNoOp() {
        let exp = expectation(forNotification: .swarmPermissionRevoked, object: nil)
        exp.isInverted = true
        store.revoke(origin: "unknown.eth")
        wait(for: [exp], timeout: 0.2)
    }

    func testTouchLastUsedAdvancesTimestamp() async throws {
        store.grant(origin: "foo.eth")
        let descriptor = FetchDescriptor<SwarmPermission>(
            predicate: #Predicate { $0.origin == "foo.eth" }
        )
        let initial = try XCTUnwrap(container.mainContext.fetch(descriptor).first?.lastUsedAt)
        try await Task.sleep(nanoseconds: 10_000_000)  // 10ms — coarse enough for `Date.now`
        store.touchLastUsed(origin: "foo.eth")
        let updated = try XCTUnwrap(container.mainContext.fetch(descriptor).first?.lastUsedAt)
        XCTAssertGreaterThan(updated, initial)
    }

    // MARK: - autoApproveFeeds (WP6.1)

    func testAutoApproveFeedsDefaultsToFalse() {
        store.grant(origin: "foo.eth")
        XCTAssertFalse(store.isAutoApproveFeeds(origin: "foo.eth"))
    }

    func testSetAutoApproveFeedsRoundtrip() {
        store.grant(origin: "foo.eth")
        store.setAutoApproveFeeds(origin: "foo.eth", enabled: true)
        XCTAssertTrue(store.isAutoApproveFeeds(origin: "foo.eth"))
        store.setAutoApproveFeeds(origin: "foo.eth", enabled: false)
        XCTAssertFalse(store.isAutoApproveFeeds(origin: "foo.eth"))
    }

    func testSetAutoApproveFeedsOnUnknownOriginIsNoOp() {
        // No grant exists — must not crash, must not create a stub row.
        store.setAutoApproveFeeds(origin: "ghost.eth", enabled: true)
        XCTAssertFalse(store.isAutoApproveFeeds(origin: "ghost.eth"))
    }

    func testAutoApproveFlagsAreIndependent() {
        store.grant(origin: "foo.eth")
        store.setAutoApprovePublish(origin: "foo.eth", enabled: true)
        XCTAssertTrue(store.isAutoApprovePublish(origin: "foo.eth"))
        XCTAssertFalse(store.isAutoApproveFeeds(origin: "foo.eth"))
    }
}
