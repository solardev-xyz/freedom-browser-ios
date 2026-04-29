import XCTest
@testable import Freedom

@MainActor
final class SwarmBridgeTests: XCTestCase {
    private var fixture: SwarmBridgeTestFixture!

    private let connectedOrigin = OriginIdentity.from(string: "https://app.uniswap.org")!
    private let httpOrigin = OriginIdentity.from(string: "http://evil.example.com")!

    override func setUp() async throws {
        fixture = try await SwarmBridgeTestFixture()
    }

    override func tearDown() async throws {
        try await fixture.tearDownAsync()
        fixture = nil
    }

    // MARK: - swarm_requestAccess sanity (no service calls, no bee)

    func testRequestAccessIneligibleOriginReturnsUnauthorized() async {
        await fixture.dispatch(method: "swarm_requestAccess", origin: httpOrigin)
        XCTAssertEqual(fixture.recorder.errors.count, 1)
        XCTAssertEqual(fixture.recorder.errors.first?.id, 1)
        XCTAssertEqual(fixture.recorder.errors.first?.dict["code"] as? Int, 4100)
    }

    func testRequestAccessAlreadyConnectedSkipsSheetAndReturnsResult() async throws {
        // Pre-grant — handler must take the fast path (no sheet).
        fixture.permissionStore.grant(origin: connectedOrigin.key)

        await fixture.dispatch(method: "swarm_requestAccess", origin: connectedOrigin)

        XCTAssertEqual(fixture.recorder.errors.count, 0)
        XCTAssertEqual(fixture.recorder.results.count, 1)
        let result = try XCTUnwrap(fixture.recorder.results.first?.value as? [String: Any])
        XCTAssertEqual(result["connected"] as? Bool, true)
        XCTAssertEqual(result["origin"] as? String, connectedOrigin.key)
        XCTAssertEqual(result["capabilities"] as? [String], ["publish"])
        // Fast path: no parked approval, no `connect` event.
        XCTAssertNil(fixture.host.pendingSwarmApproval)
        XCTAssertEqual(fixture.recorder.events.count, 0)
    }
}
