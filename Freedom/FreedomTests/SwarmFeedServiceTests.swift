import XCTest
@testable import Freedom

@MainActor
final class SwarmFeedServiceTests: XCTestCase {
    private let testOwner = "19e7e376e7c213b7e7e7e46cc70a5dd086daff2a"
    private let testTopic = "f757932a4cab2ba386df56c48cff6abd0515ed9e4ca464d44facb942bf1790b5"
    private let testBatchID = String(repeating: "ab", count: 32)
    private let testManifestRef = String(repeating: "cd", count: 32)

    func testCreateFeedHappyPath() async throws {
        var capturedArgs: (owner: String, topic: String, batchID: String)?
        let service = SwarmFeedService { owner, topic, batchID in
            capturedArgs = (owner, topic, batchID)
            return self.testManifestRef
        }
        let result = try await service.createFeed(
            ownerHex: testOwner, topicHex: testTopic, batchID: testBatchID
        )
        XCTAssertEqual(capturedArgs?.owner, testOwner)
        XCTAssertEqual(capturedArgs?.topic, testTopic)
        XCTAssertEqual(capturedArgs?.batchID, testBatchID)
        XCTAssertEqual(result.ownerHex, testOwner)
        XCTAssertEqual(result.topic, testTopic)
        XCTAssertEqual(result.manifestReference, testManifestRef)
        XCTAssertEqual(result.bzzUrl, "bzz://\(testManifestRef)")
    }

    func testCreateFeedMapsBeeNotRunningToUnreachable() async {
        let service = SwarmFeedService { _, _, _ in
            throw BeeAPIClient.Error.notRunning
        }
        await assertThrows(SwarmFeedService.FeedServiceError.unreachable) {
            try await service.createFeed(
                ownerHex: testOwner, topicHex: testTopic, batchID: testBatchID
            )
        }
    }

    func testCreateFeedMapsMalformedResponse() async {
        let service = SwarmFeedService { _, _, _ in
            throw BeeAPIClient.Error.malformedResponse
        }
        await assertThrows(SwarmFeedService.FeedServiceError.malformedResponse) {
            try await service.createFeed(
                ownerHex: testOwner, topicHex: testTopic, batchID: testBatchID
            )
        }
    }

    func testCreateFeedWrapsUnknownErrors() async {
        struct Boom: Swift.Error {}
        let service = SwarmFeedService { _, _, _ in throw Boom() }
        do {
            _ = try await service.createFeed(
                ownerHex: testOwner, topicHex: testTopic, batchID: testBatchID
            )
            XCTFail("Expected throw")
        } catch let SwarmFeedService.FeedServiceError.other(message) {
            XCTAssertTrue(message.contains("Boom"),
                          "expected wrapped error, got: \(message)")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - Helpers

    private func assertThrows<E: Swift.Error & Equatable>(
        _ expected: E,
        _ body: () async throws -> Void,
        file: StaticString = #file, line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("Expected throw of \(expected)", file: file, line: line)
        } catch let actual as E where actual == expected {
            // ok
        } catch {
            XCTFail("Wrong error: \(error)", file: file, line: line)
        }
    }
}
