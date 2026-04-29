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

    // MARK: - writeFeedEntry

    /// Auto-index path: empty feed → write at index 0. Service builds
    /// a CAC over the raw payload (since payload <= 4 KB) and uploads
    /// without the wrap path being touched.
    func testWriteFeedEntryAutoIndexEmptyFeed() async throws {
        var capturedBody: Data?
        let service = makeService(
            readFeed: { _, _, _ in throw BeeAPIClient.Error.notFound },
            uploadSOC: { _, _, _, body, _ in
                capturedBody = body
                return (reference: self.testManifestRef, tagUid: 7)
            }
        )
        let result = try await service.writeFeedEntry(
            ownerHex: testOwner, topicHex: testTopic,
            payload: Data("hello".utf8),
            explicitIndex: nil,
            privateKey: testPrivateKey, batchID: testBatchID
        )
        XCTAssertEqual(result.index, 0)
        XCTAssertEqual(result.tagUid, 7)
        // Body = span(8) || payload(5) = 13 bytes.
        XCTAssertEqual(capturedBody?.count, 13)
    }

    /// Auto-increment continues from `feedIndexNext` returned by
    /// the latest read.
    func testWriteFeedEntryAutoIndexUsesNextIndex() async throws {
        let service = makeService(
            readFeed: { _, _, _ in
                BeeAPIClient.FeedReadResult(payload: Data(), index: 4, nextIndex: 5)
            },
            uploadSOC: { _, _, _, _, _ in
                (reference: self.testManifestRef, tagUid: nil)
            }
        )
        let result = try await service.writeFeedEntry(
            ownerHex: testOwner, topicHex: testTopic,
            payload: Data("hello".utf8),
            explicitIndex: nil,
            privateKey: testPrivateKey, batchID: testBatchID
        )
        XCTAssertEqual(result.index, 5)
    }

    /// Explicit-index write where no SOC exists at that index: service
    /// probes via `getChunk(socAddress)`, gets 404, proceeds. The
    /// probe uses the SOC-address (exact match), not `/feeds/...?index`
    /// (which does epoch-based "at-or-before" search and would falsely
    /// flag every probe past index 0).
    func testWriteFeedEntryExplicitIndexAvailable() async throws {
        var probedAddress: String?
        let service = makeService(
            uploadSOC: { _, _, _, _, _ in
                (reference: self.testManifestRef, tagUid: nil)
            },
            getChunk: { ref in
                probedAddress = ref
                throw BeeAPIClient.Error.notFound
            }
        )
        let result = try await service.writeFeedEntry(
            ownerHex: testOwner, topicHex: testTopic,
            payload: Data("hello".utf8),
            explicitIndex: 42,
            privateKey: testPrivateKey, batchID: testBatchID
        )
        // Probe targets the SOC address for (topic, index=42).
        let expectedIdentifier = SwarmSOC.feedIdentifier(
            topic: Data(hex: testTopic)!, index: 42
        )
        let expectedAddress = SwarmSOC.socAddress(
            identifier: expectedIdentifier,
            ownerAddress: Data(hex: testOwner)!
        ).hexString
        XCTAssertEqual(probedAddress, expectedAddress)
        XCTAssertEqual(result.index, 42)
    }

    /// SWIP-required overwrite protection: explicit index where the
    /// SOC chunk already exists → throw `indexAlreadyExists`. Bridge
    /// maps to `-32602` with `data.reason = "index_already_exists"`.
    func testWriteFeedEntryExplicitIndexCollisionThrows() async {
        let service = makeService(
            getChunk: { _ in Data(repeating: 0xff, count: 105) }  // SOC envelope
        )
        do {
            _ = try await service.writeFeedEntry(
                ownerHex: testOwner, topicHex: testTopic,
                payload: Data("hello".utf8),
                explicitIndex: 42,
                privateKey: testPrivateKey, batchID: testBatchID
            )
            XCTFail("Expected indexAlreadyExists")
        } catch SwarmFeedService.FeedServiceError.indexAlreadyExists(let index) {
            XCTAssertEqual(index, 42)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    /// > 4 KB payload routes through the wrap path: uploadBytes →
    /// getChunk → wrap as SOC. Service should call both new
    /// closures, and the resulting SOC body matches the bee-returned
    /// chunk (span_8 || payload).
    func testWriteFeedEntryLargePayloadRoutesThroughWrapPath() async throws {
        let largePayload = Data(repeating: 0xab, count: 5000)
        let testRootRef = String(repeating: "f0", count: 32)
        // Simulated root-chunk bytes from bee: span(8) + 32-byte
        // BMT-tree root reference. Real bee returns the actual tree
        // bytes; for the test we just need a well-formed shape.
        let rootChunkSpan = Data([0x88, 0x13, 0, 0, 0, 0, 0, 0])  // 5000 LE
        let rootChunkPayload = Data(repeating: 0xcc, count: 32)
        let rootChunkBytes = rootChunkSpan + rootChunkPayload

        var uploadBytesCalled = false
        var getChunkCalled = false
        var capturedSocBody: Data?
        let service = makeService(
            readFeed: { _, _, _ in throw BeeAPIClient.Error.notFound },
            uploadSOC: { _, _, _, body, _ in
                capturedSocBody = body
                return (reference: self.testManifestRef, tagUid: nil)
            },
            uploadBytes: { payload, _ in
                uploadBytesCalled = true
                XCTAssertEqual(payload.count, 5000)
                return testRootRef
            },
            getChunk: { ref in
                getChunkCalled = true
                XCTAssertEqual(ref, testRootRef)
                return rootChunkBytes
            }
        )
        let result = try await service.writeFeedEntry(
            ownerHex: testOwner, topicHex: testTopic,
            payload: largePayload,
            explicitIndex: nil,
            privateKey: testPrivateKey, batchID: testBatchID
        )
        XCTAssertTrue(uploadBytesCalled)
        XCTAssertTrue(getChunkCalled)
        XCTAssertEqual(result.index, 0)
        // SOC body wraps the root chunk: span_8 || rootChunkPayload_32.
        XCTAssertEqual(capturedSocBody?.count, 8 + 32)
        XCTAssertEqual(capturedSocBody?.prefix(8), rootChunkSpan)
    }

    func testWriteFeedEntryRejectsEmptyPayload() async {
        let service = makeService()
        do {
            _ = try await service.writeFeedEntry(
                ownerHex: testOwner, topicHex: testTopic,
                payload: Data(),
                explicitIndex: nil,
                privateKey: testPrivateKey, batchID: testBatchID
            )
            XCTFail("Expected throw")
        } catch let SwarmFeedService.FeedServiceError.other(message) {
            XCTAssertTrue(message.contains("empty"),
                          "expected empty-payload error, got: \(message)")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testWriteFeedEntryMapsUnreachableOnExplicitIndexProbe() async {
        let service = makeService(
            getChunk: { _ in throw BeeAPIClient.Error.notRunning }
        )
        await assertThrows(SwarmFeedService.FeedServiceError.unreachable) {
            try await service.writeFeedEntry(
                ownerHex: self.testOwner, topicHex: self.testTopic,
                payload: Data("hello".utf8),
                explicitIndex: 5,
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
        uploadSOC: SwarmFeedService.UploadSOC? = nil,
        uploadBytes: SwarmFeedService.UploadBytes? = nil,
        getChunk: SwarmFeedService.GetChunk? = nil
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
            },
            uploadBytes: uploadBytes ?? { _, _ in
                XCTFail("uploadBytes unexpectedly called"); return ""
            },
            getChunk: getChunk ?? { _ in
                XCTFail("getChunk unexpectedly called"); return Data()
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
