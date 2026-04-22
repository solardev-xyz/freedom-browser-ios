import XCTest
@testable import Freedom

final class SmokeTests: XCTestCase {
    func testTestTargetWiredUp() {
        XCTAssertEqual(BlockAnchor.latest.rawValue, "latest")
    }
}
