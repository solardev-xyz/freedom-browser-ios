import XCTest
@testable import Freedom

@MainActor
final class SwarmReadBudgetTests: XCTestCase {
    func testAnonymousRequestCapAt120() async {
        let budget = SwarmReadBudget()
        for _ in 0..<120 {
            XCTAssertTrue(budget.admit(origin: "foo.eth", isConnected: false))
        }
        XCTAssertFalse(budget.admit(origin: "foo.eth", isConnected: false))
    }

    func testConnectedRequestCapAt600() async {
        let budget = SwarmReadBudget()
        for _ in 0..<600 {
            XCTAssertTrue(budget.admit(origin: "foo.eth", isConnected: true))
        }
        XCTAssertFalse(budget.admit(origin: "foo.eth", isConnected: true))
    }

    func testBudgetsAreOriginScoped() async {
        let budget = SwarmReadBudget()
        for _ in 0..<120 {
            _ = budget.admit(origin: "foo.eth", isConnected: false)
        }
        XCTAssertFalse(budget.admit(origin: "foo.eth", isConnected: false))
        XCTAssertTrue(budget.admit(origin: "bar.eth", isConnected: false))
    }

    func testByteBudgetBlocksSubsequentReads() async {
        let budget = SwarmReadBudget()
        XCTAssertTrue(budget.admit(origin: "foo.eth", isConnected: false))
        budget.recordBytes(origin: "foo.eth", bytes: 512 * 1024)
        XCTAssertFalse(budget.admit(origin: "foo.eth", isConnected: false))
        // Connected origins have the larger 5 MB byte budget.
        XCTAssertTrue(budget.admit(origin: "connected.eth", isConnected: true))
        budget.recordBytes(origin: "connected.eth", bytes: 512 * 1024)
        XCTAssertTrue(budget.admit(origin: "connected.eth", isConnected: true))
    }

    func testWindowRollsAfter60Seconds() async {
        var currentTime = Date(timeIntervalSince1970: 1_000)
        let budget = SwarmReadBudget(now: { currentTime })
        for _ in 0..<120 {
            _ = budget.admit(origin: "foo.eth", isConnected: false)
        }
        XCTAssertFalse(budget.admit(origin: "foo.eth", isConnected: false))
        currentTime = currentTime.addingTimeInterval(61)
        XCTAssertTrue(budget.admit(origin: "foo.eth", isConnected: false))
    }
}
