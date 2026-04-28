import XCTest
@testable import Freedom

@MainActor
final class SwarmReadFeedEntryTests: XCTestCase {
    private let origin = OriginIdentity.from(string: "ens://foo.eth")!
    private let validTopic = String(repeating: "a", count: 64)
    private let validOwner = "0x1111111111111111111111111111111111111111"

    /// Successful read returns this fixed payload so we can assert the
    /// SWIP wire shape without coupling to bee.
    private let payloadBytes = Data([0x68, 0x69])  // "hi"

    // MARK: - Builder

    private struct Stubs {
        var owners: [String: String] = [:]  // "{origin}/{name}" → owner hex
        /// Throw a `FeedReadError` case to simulate bee 404 / unreachable.
        var readResult: Result<SwarmRouter.FeedRead, Swift.Error> = .success(
            .init(payload: Data(), index: 0, nextIndex: nil)
        )
    }

    private func makeRouter(_ stubs: Stubs) -> SwarmRouter {
        SwarmRouter(
            isConnected: { _ in false },
            listFeedsForOrigin: { _ in [] },
            nodeFailureReason: { nil },
            feedOwner: { origin, name in stubs.owners["\(origin)/\(name)"] },
            readFeed: { _, _, _ in try stubs.readResult.get() }
        )
    }

    // MARK: - Param validation

    func testRejectsBothTopicAndName() async {
        let router = makeRouter(.init())
        await expectInvalidParams(
            router: router, params: ["topic": validTopic, "name": "posts"]
        )
    }

    func testRejectsNeitherTopicNorName() async {
        let router = makeRouter(.init())
        await expectInvalidParams(router: router, params: [:])
    }

    func testRejectsTopicWithBadHex() async {
        let router = makeRouter(.init())
        await expectInvalidParams(
            router: router,
            params: ["topic": String(repeating: "z", count: 64), "owner": validOwner],
            reason: SwarmRouter.ErrorPayload.Reason.invalidTopic
        )
    }

    func testRejectsTopicWithoutOwner() async {
        let router = makeRouter(.init())
        await expectInvalidParams(
            router: router,
            params: ["topic": validTopic],
            reason: SwarmRouter.ErrorPayload.Reason.invalidOwner
        )
    }

    func testRejectsTopicWithMalformedOwner() async {
        let router = makeRouter(.init())
        await expectInvalidParams(
            router: router,
            params: ["topic": validTopic, "owner": "0xdeadbeef"],
            reason: SwarmRouter.ErrorPayload.Reason.invalidOwner
        )
    }

    func testRejectsEmptyName() async {
        let router = makeRouter(.init())
        await expectInvalidParams(
            router: router, params: ["name": ""],
            reason: SwarmRouter.ErrorPayload.Reason.invalidFeedName
        )
    }

    func testRejectsNameWithSlash() async {
        let router = makeRouter(.init())
        await expectInvalidParams(
            router: router, params: ["name": "foo/bar"],
            reason: SwarmRouter.ErrorPayload.Reason.invalidFeedName
        )
    }

    func testRejectsNegativeIndex() async {
        let router = makeRouter(.init())
        await expectInvalidParams(
            router: router,
            params: ["topic": validTopic, "owner": validOwner, "index": -1]
        )
    }

    func testRejectsNonIntegerIndex() async {
        let router = makeRouter(.init())
        await expectInvalidParams(
            router: router,
            params: ["topic": validTopic, "owner": validOwner, "index": "five"]
        )
    }

    // MARK: - Owner resolution

    func testNameWithoutOwnerNotInStoreReturnsFeedNotFound() async {
        // No record in `owners` → SWIP "feed_not_found".
        let router = makeRouter(.init())
        await expectInvalidParams(
            router: router, params: ["name": "posts"],
            reason: SwarmRouter.ErrorPayload.Reason.feedNotFound
        )
    }

    func testNameWithoutOwnerLooksUpInStore() async throws {
        // Stored owner present → router uses it for the bee call.
        var stubs = Stubs()
        stubs.owners["\(origin.key)/posts"] = validOwner
        stubs.readResult = .success(.init(
            payload: payloadBytes, index: 0, nextIndex: 1
        ))
        let router = makeRouter(stubs)
        let result = try await router.readFeedEntry(
            params: ["name": "posts"], origin: origin
        )
        XCTAssertEqual(result["data"] as? String, payloadBytes.base64EncodedString())
    }

    func testNameWithExplicitOwnerOverridesStore() async throws {
        var stubs = Stubs()
        stubs.owners["\(origin.key)/posts"] = "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        stubs.readResult = .success(.init(
            payload: payloadBytes, index: 0, nextIndex: nil
        ))
        let router = makeRouter(stubs)
        // Should not throw — explicit owner is valid 40-hex, takes priority.
        _ = try await router.readFeedEntry(
            params: ["name": "posts", "owner": validOwner], origin: origin
        )
    }

    // MARK: - Pre-flight

    func testReturnsNodeStoppedWhenBeeUnreachable() async {
        var stubs = Stubs()
        stubs.readResult = .failure(SwarmRouter.FeedReadError.unreachable)
        let router = makeRouter(stubs)
        do {
            _ = try await router.readFeedEntry(
                params: ["topic": validTopic, "owner": validOwner],
                origin: origin
            )
            XCTFail("expected nodeUnavailable")
        } catch SwarmRouter.RouterError.nodeUnavailable(let reason) {
            XCTAssertEqual(reason, SwarmRouter.ErrorPayload.Reason.nodeStopped)
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    // MARK: - bee 404 mapping

    func testBeeNotFoundWithoutIndexMapsToFeedEmpty() async {
        var stubs = Stubs()
        stubs.readResult = .failure(SwarmRouter.FeedReadError.notFound)
        await expectInvalidParams(
            router: makeRouter(stubs),
            params: ["topic": validTopic, "owner": validOwner],
            reason: SwarmRouter.ErrorPayload.Reason.feedEmpty
        )
    }

    func testBeeNotFoundWithIndexMapsToEntryNotFound() async {
        var stubs = Stubs()
        stubs.readResult = .failure(SwarmRouter.FeedReadError.notFound)
        await expectInvalidParams(
            router: makeRouter(stubs),
            params: ["topic": validTopic, "owner": validOwner, "index": 0],
            reason: SwarmRouter.ErrorPayload.Reason.entryNotFound
        )
    }

    // MARK: - Result shape

    func testLatestReadIncludesNextIndexWhenBeeProvidesIt() async throws {
        var stubs = Stubs()
        stubs.readResult = .success(.init(
            payload: payloadBytes, index: 5, nextIndex: 6
        ))
        let router = makeRouter(stubs)
        let result = try await router.readFeedEntry(
            params: ["topic": validTopic, "owner": validOwner], origin: origin
        )
        XCTAssertEqual(result["index"] as? Int, 5)
        XCTAssertEqual(result["nextIndex"] as? Int, 6)
        XCTAssertEqual(result["encoding"] as? String, "base64")
    }

    func testSpecificIndexReadHasNullNextIndex() async throws {
        var stubs = Stubs()
        stubs.readResult = .success(.init(
            payload: payloadBytes, index: 3, nextIndex: 4  // bee reports it; SWIP says drop
        ))
        let router = makeRouter(stubs)
        let result = try await router.readFeedEntry(
            params: ["topic": validTopic, "owner": validOwner, "index": 3],
            origin: origin
        )
        XCTAssertEqual(result["index"] as? Int, 3)
        XCTAssertTrue(result["nextIndex"] is NSNull)
    }

    // MARK: - Helpers

    private func expectInvalidParams(
        router: SwarmRouter,
        params: [String: Any],
        reason expected: String? = nil,
        file: StaticString = #file, line: UInt = #line
    ) async {
        do {
            _ = try await router.readFeedEntry(params: params, origin: origin)
            XCTFail("expected invalidParams", file: file, line: line)
        } catch SwarmRouter.RouterError.invalidParams(let reason, _) {
            if let expected {
                XCTAssertEqual(reason, expected, file: file, line: line)
            }
        } catch {
            XCTFail("unexpected: \(error)", file: file, line: line)
        }
    }
}
