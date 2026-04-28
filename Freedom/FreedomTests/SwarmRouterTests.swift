import XCTest
@testable import Freedom

@MainActor
final class SwarmRouterTests: XCTestCase {
    /// Set per test before calling `makeRouter`.
    private var connected: Set<String> = []
    private var feedsByOrigin: [String: [[String: Any]]] = [:]
    private var nodeReason: String?

    private let connectedOrigin = OriginIdentity.from(string: "ens://foo.eth")!

    override func setUp() {
        super.setUp()
        connected = []
        feedsByOrigin = [:]
        nodeReason = nil
    }

    private func makeRouter() -> SwarmRouter {
        // Snapshot the per-test state so the router's closures don't
        // hold back-references to the XCTestCase instance — XCTest's
        // sync-test teardown timing tripped a malloc fault when a class
        // captured `self` via either `[unowned self]` or `[weak self]`.
        let connected = self.connected
        let feeds = self.feedsByOrigin
        let reason = self.nodeReason
        return SwarmRouter(
            isConnected: { connected.contains($0) },
            listFeedsForOrigin: { feeds[$0] ?? [] },
            nodeFailureReason: { reason },
            feedOwner: { _, _ in nil },
            readFeed: { _, _, _ in throw SwarmRouter.FeedReadError.notFound }
        )
    }

    // MARK: - getCapabilities

    func testCapabilitiesReportsNotConnectedBeforeGrant() async {
        let caps = makeRouter().capabilities(origin: connectedOrigin)
        XCTAssertFalse(caps.canPublish)
        XCTAssertEqual(caps.reason, "not-connected")
    }

    func testCapabilitiesReportsNodeFailureWhenConnectedButNodeNotReady() async {
        connected.insert(connectedOrigin.key)
        nodeReason = SwarmRouter.ErrorPayload.Reason.ultraLightMode
        let caps = makeRouter().capabilities(origin: connectedOrigin)
        XCTAssertFalse(caps.canPublish)
        XCTAssertEqual(caps.reason, "ultra-light-mode")
    }

    func testCapabilitiesGreenWhenConnectedAndNodeReady() async {
        connected.insert(connectedOrigin.key)
        let caps = makeRouter().capabilities(origin: connectedOrigin)
        XCTAssertTrue(caps.canPublish)
        XCTAssertNil(caps.reason)
    }

    func testCapabilitiesPrioritizesNotConnectedOverNodeFailure() async {
        // SWIP §"swarm_getCapabilities" — `not-connected` shadows node-side
        // reasons so the dapp shows "connect first" instead of "your bee
        // node is in ultralight mode" before the user has ever connected.
        nodeReason = SwarmRouter.ErrorPayload.Reason.nodeStopped
        let caps = makeRouter().capabilities(origin: connectedOrigin)
        XCTAssertEqual(caps.reason, "not-connected")
    }

    // MARK: - listFeeds

    func testListFeedsEmptyForUngrantedOrigin() async {
        let result = makeRouter().listFeeds(origin: connectedOrigin)
        XCTAssertEqual(result.count, 0)
    }

    func testListFeedsScopedToCallingOrigin() async {
        feedsByOrigin[connectedOrigin.key] = [["name": "posts"]]
        feedsByOrigin["bar.eth"] = [["name": "posts"]]
        let result = makeRouter().listFeeds(origin: connectedOrigin)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?["name"] as? String, "posts")
    }

    // MARK: - dispatch

    func testHandleDispatchesGetCapabilities() async throws {
        let result = try await makeRouter().handle(
            method: "swarm_getCapabilities", params: [:], origin: connectedOrigin
        )
        let dict = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(dict["specVersion"] as? String, "1.0")
        XCTAssertEqual(dict["reason"] as? String, "not-connected")
    }

    func testHandleDispatchesListFeeds() async throws {
        let result = try await makeRouter().handle(
            method: "swarm_listFeeds", params: [:], origin: connectedOrigin
        )
        XCTAssertEqual((result as? [[String: Any]])?.count, 0)
    }

    func testHandleRejectsUnknownMethodAs4200() async {
        do {
            _ = try await makeRouter().handle(
                method: "swarm_doesNotExist", params: [:], origin: connectedOrigin
            )
            XCTFail("Expected unsupportedMethod")
        } catch SwarmRouter.RouterError.unsupportedMethod(let method) {
            XCTAssertEqual(method, "swarm_doesNotExist")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHandleRejectsPublishMethodsAs4200ForNow() async {
        // WP4 ships only the read-only methods. Publish/feed-write methods
        // surface as 4200 until WP5/WP6 land — explicit guard so a half-
        // wired bridge can't accidentally call into a missing handler.
        let methods = [
            "swarm_publishData", "swarm_publishFiles", "swarm_getUploadStatus",
            "swarm_createFeed", "swarm_updateFeed", "swarm_writeFeedEntry",
        ]
        for method in methods {
            do {
                _ = try await makeRouter().handle(method: method, params: [:], origin: connectedOrigin)
                XCTFail("Expected \(method) to throw unsupportedMethod")
            } catch SwarmRouter.RouterError.unsupportedMethod {
            } catch {
                XCTFail("\(method) threw unexpected: \(error)")
            }
        }
    }

    // MARK: - errorPayload

    func testErrorPayloadMapsRouterErrors() async {
        let router = makeRouter()
        XCTAssertEqual(
            router.errorPayload(for: SwarmRouter.RouterError.unsupportedMethod(method: "foo")).code,
            4200
        )
        let invalidParams = router.errorPayload(for: SwarmRouter.RouterError.invalidParams(
            reason: "invalid_topic", message: "topic must be 64 hex chars"
        ))
        XCTAssertEqual(invalidParams.code, -32602)
        XCTAssertEqual(invalidParams.dataReason, "invalid_topic")

        let nodeUnavailable = router.errorPayload(for: SwarmRouter.RouterError.nodeUnavailable(
            reason: "node-stopped"
        ))
        XCTAssertEqual(nodeUnavailable.code, 4900)
        XCTAssertEqual(nodeUnavailable.dataReason, "node-stopped")
    }

    func testErrorPayloadMapsUnknownErrorTo32603() async {
        struct Unknown: Swift.Error {}
        let payload = makeRouter().errorPayload(for: Unknown())
        XCTAssertEqual(payload.code, -32603)
    }
}
