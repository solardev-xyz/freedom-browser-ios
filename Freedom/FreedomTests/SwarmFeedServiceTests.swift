import XCTest
@testable import Freedom

@MainActor
final class SwarmFeedServiceTests: XCTestCase {
    private let testOwner = "19e7e376e7c213b7e7e7e46cc70a5dd086daff2a"
    private let testTopic = "f757932a4cab2ba386df56c48cff6abd0515ed9e4ca464d44facb942bf1790b5"
    private let testBatchID = String(repeating: "ab", count: 32)
    private let testManifestRef = String(repeating: "cd", count: 32)
    private let testContentRef = String(repeating: "11", count: 32)
    /// Test private key matching the captured-fixture owner above —
    /// shared with `SwarmSOCTests` / `FeedSignerTests`.
    private let testPrivateKey = Data(hex: String(repeating: "11", count: 32))!

    // MARK: - createFeed

    func testCreateFeedHappyPath() async throws {
        var capturedArgs: (owner: String, topic: String, batchID: String)?
        let service = makeService(
            createManifest: { owner, topic, batchID in
                capturedArgs = (owner, topic, batchID)
                return self.testManifestRef
            }
        )
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
        let service = makeService(
            createManifest: { _, _, _ in throw BeeAPIClient.Error.notRunning }
        )
        await assertThrows(SwarmFeedService.FeedServiceError.unreachable) {
            try await service.createFeed(
                ownerHex: self.testOwner, topicHex: self.testTopic, batchID: self.testBatchID
            )
        }
    }

    func testCreateFeedMapsMalformedResponse() async {
        let service = makeService(
            createManifest: { _, _, _ in throw BeeAPIClient.Error.malformedResponse }
        )
        await assertThrows(SwarmFeedService.FeedServiceError.malformedResponse) {
            try await service.createFeed(
                ownerHex: self.testOwner, topicHex: self.testTopic, batchID: self.testBatchID
            )
        }
    }

    func testCreateFeedWrapsUnknownErrors() async {
        struct Boom: Swift.Error {}
        let service = makeService(
            createManifest: { _, _, _ in throw Boom() }
        )
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

    // MARK: - updateFeed

    /// Empty feed (bee 404 on latest read) starts at index 0; SOC body
    /// is `timestamp_8 || reference_32` = 40 bytes; uploadSOC receives
    /// the right owner / identifier / sig / batchID and the body is
    /// `span_8 || payload_40` = 48 bytes.
    func testUpdateFeedOnEmptyFeedStartsAtIndexZero() async throws {
        var captured: (owner: String, identifier: String, sig: String, body: Data, batchID: String)?
        let service = makeService(
            readFeed: { _, _, _ in throw BeeAPIClient.Error.notFound },
            uploadSOC: { owner, identifier, sig, body, batchID in
                captured = (owner, identifier, sig, body, batchID)
                return (reference: self.testManifestRef, tagUid: 7)
            }
        )
        let result = try await service.updateFeed(
            ownerHex: testOwner, topicHex: testTopic,
            contentReference: testContentRef,
            privateKey: testPrivateKey,
            batchID: testBatchID
        )
        XCTAssertEqual(result.index, 0)
        XCTAssertEqual(result.socReference, testManifestRef)
        XCTAssertEqual(result.tagUid, 7)
        XCTAssertEqual(captured?.owner, testOwner)
        XCTAssertEqual(captured?.batchID, testBatchID)
        // SOC body = span(8) || payload(timestamp 8 || reference 32) = 48 bytes.
        XCTAssertEqual(captured?.body.count, 48)
        // Identifier = keccak256(topic || index_8BE) — pinned by SwarmSOCTests
        // for (index=0); recompute and compare.
        let expectedId = SwarmSOC.feedIdentifier(
            topic: Data(hex: testTopic)!, index: 0
        ).hexString
        XCTAssertEqual(captured?.identifier, expectedId)
    }

    /// Non-empty feed: `feedIndexNext` from the latest read drives the
    /// next index. Bee provides nextIndex on latest-update reads.
    func testUpdateFeedUsesFeedIndexNextWhenBeeProvidesIt() async throws {
        var capturedIdentifier: String?
        let service = makeService(
            readFeed: { _, _, _ in
                BeeAPIClient.FeedReadResult(payload: Data(), index: 4, nextIndex: 5)
            },
            uploadSOC: { _, identifier, _, _, _ in
                capturedIdentifier = identifier
                return (reference: self.testManifestRef, tagUid: nil)
            }
        )
        let result = try await service.updateFeed(
            ownerHex: testOwner, topicHex: testTopic,
            contentReference: testContentRef,
            privateKey: testPrivateKey,
            batchID: testBatchID
        )
        XCTAssertEqual(result.index, 5)
        let expectedId = SwarmSOC.feedIdentifier(
            topic: Data(hex: testTopic)!, index: 5
        ).hexString
        XCTAssertEqual(capturedIdentifier, expectedId)
    }

    /// Bee may omit `feedIndexNext`; service falls back to
    /// `feedIndex + 1`.
    func testUpdateFeedFallsBackToFeedIndexPlusOne() async throws {
        let service = makeService(
            readFeed: { _, _, _ in
                BeeAPIClient.FeedReadResult(payload: Data(), index: 9, nextIndex: nil)
            },
            uploadSOC: { _, _, _, _, _ in
                (reference: self.testManifestRef, tagUid: nil)
            }
        )
        let result = try await service.updateFeed(
            ownerHex: testOwner, topicHex: testTopic,
            contentReference: testContentRef,
            privateKey: testPrivateKey,
            batchID: testBatchID
        )
        XCTAssertEqual(result.index, 10)
    }

    func testUpdateFeedRejectsMalformedTopicHex() async {
        let service = makeService()
        do {
            _ = try await service.updateFeed(
                ownerHex: testOwner, topicHex: "not-hex",
                contentReference: testContentRef,
                privateKey: testPrivateKey, batchID: testBatchID
            )
            XCTFail("Expected throw")
        } catch let SwarmFeedService.FeedServiceError.other(message) {
            XCTAssertTrue(message.contains("topicHex"),
                          "expected topicHex error, got: \(message)")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testUpdateFeedRejectsMalformedContentReference() async {
        let service = makeService()
        do {
            _ = try await service.updateFeed(
                ownerHex: testOwner, topicHex: testTopic,
                contentReference: "not-hex",
                privateKey: testPrivateKey, batchID: testBatchID
            )
            XCTFail("Expected throw")
        } catch let SwarmFeedService.FeedServiceError.other(message) {
            XCTAssertTrue(message.contains("contentReference"),
                          "expected contentReference error, got: \(message)")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testUpdateFeedMapsReadFeedUnreachable() async {
        let service = makeService(
            readFeed: { _, _, _ in throw BeeAPIClient.Error.notRunning }
        )
        await assertThrows(SwarmFeedService.FeedServiceError.unreachable) {
            try await service.updateFeed(
                ownerHex: self.testOwner, topicHex: self.testTopic,
                contentReference: self.testContentRef,
                privateKey: self.testPrivateKey, batchID: self.testBatchID
            )
        }
    }

    func testUpdateFeedMapsUploadSOCUnreachable() async {
        let service = makeService(
            readFeed: { _, _, _ in throw BeeAPIClient.Error.notFound },
            uploadSOC: { _, _, _, _, _ in throw BeeAPIClient.Error.notRunning }
        )
        await assertThrows(SwarmFeedService.FeedServiceError.unreachable) {
            try await service.updateFeed(
                ownerHex: self.testOwner, topicHex: self.testTopic,
                contentReference: self.testContentRef,
                privateKey: self.testPrivateKey, batchID: self.testBatchID
            )
        }
    }

    // MARK: - Helpers

    /// Builds a service with stubbable closures. Defaults throw to
    /// surface "wrong closure called" via `FeedServiceError.other`.
    private func makeService(
        createManifest: SwarmFeedService.CreateManifest? = nil,
        readFeed: SwarmFeedService.ReadFeed? = nil,
        uploadSOC: SwarmFeedService.UploadSOC? = nil
    ) -> SwarmFeedService {
        SwarmFeedService(
            createFeedManifest: createManifest ?? { _, _, _ in
                XCTFail("createFeedManifest unexpectedly called"); return ""
            },
            readFeed: readFeed ?? { _, _, _ in
                XCTFail("readFeed unexpectedly called")
                return BeeAPIClient.FeedReadResult(payload: Data(), index: 0, nextIndex: nil)
            },
            uploadSOC: uploadSOC ?? { _, _, _, _, _ in
                XCTFail("uploadSOC unexpectedly called")
                return (reference: "", tagUid: nil)
            }
        )
    }

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
