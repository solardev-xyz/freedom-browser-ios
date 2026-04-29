import SwiftData
import XCTest
@testable import Freedom

@MainActor
final class PermissionStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var store: PermissionStore!

    override func setUp() async throws {
        container = try inMemoryContainer(for: DappPermission.self)
        store = PermissionStore(context: container.mainContext)
    }

    func testGrantThenIsConnected() {
        XCTAssertFalse(store.isConnected("foo.eth"))
        store.grant(origin: "foo.eth", account: "0xabc")
        XCTAssertTrue(store.isConnected("foo.eth"))
        XCTAssertEqual(store.accounts(for: "foo.eth"), ["0xabc"])
    }

    func testGrantOverwritesExistingAccount() {
        store.grant(origin: "foo.eth", account: "0xabc")
        store.grant(origin: "foo.eth", account: "0xdef")
        XCTAssertEqual(store.accounts(for: "foo.eth"), ["0xdef"])
    }

    func testRevokeDropsGrantAndPostsNotification() {
        store.grant(origin: "foo.eth", account: "0xabc")
        let exp = expectation(forNotification: .walletPermissionRevoked, object: nil) { n in
            (n.userInfo?["origin"] as? String) == "foo.eth"
        }
        store.revoke(origin: "foo.eth")
        wait(for: [exp], timeout: 1.0)
        XCTAssertFalse(store.isConnected("foo.eth"))
        XCTAssertEqual(store.accounts(for: "foo.eth"), [])
    }

    func testRevokeOfUnknownOriginIsNoOp() {
        // No grant, no notification, no crash.
        let exp = expectation(forNotification: .walletPermissionRevoked, object: nil)
        exp.isInverted = true
        store.revoke(origin: "unknown.eth")
        wait(for: [exp], timeout: 0.2)
    }

}
