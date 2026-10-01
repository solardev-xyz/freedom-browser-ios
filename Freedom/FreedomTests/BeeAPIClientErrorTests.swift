import XCTest
@testable import Freedom

/// Bee's 4xx bodies reach the user instead of collapsing into
/// "malformed response".
final class BeeAPIClientErrorTests: XCTestCase {
    func testRejectionCarriesBeesMessage() {
        let body = Data(#"{"code":400,"message":"invalid postage batch id"}"#.utf8)
        XCTAssertEqual(
            BeeAPIClient.Error.rejection(status: 400, body: body),
            .rejected(status: 400, message: "invalid postage batch id")
        )
    }

    func testRejectionFallsBackToBodyTextThenStatus() {
        XCTAssertEqual(
            BeeAPIClient.Error.rejection(status: 402, body: Data("payment required\n".utf8)),
            .rejected(status: 402, message: "payment required")
        )
        XCTAssertEqual(
            BeeAPIClient.Error.rejection(status: 403, body: Data()),
            .rejected(status: 403, message: "The Swarm node rejected the request (HTTP 403).")
        )
    }

    func testErrorsAreLocalized() {
        XCTAssertEqual(BeeAPIClient.Error.rejected(status: 400, message: "nope").localizedDescription, "nope")
        XCTAssertEqual(BeeAPIClient.Error.notRunning.localizedDescription, "The Swarm node isn't running.")
        XCTAssertEqual(BeeAPIClient.Error.transient(503).localizedDescription, "The Swarm node is busy (HTTP 503). Try again shortly.")
    }
}
