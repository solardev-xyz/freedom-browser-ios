import XCTest
@testable import Freedom

/// Asserts every successful (and approved-but-failed) `window.swarm`
/// publish writes a `SwarmPublishHistoryRecord`, while pre-flight
/// rejections and user-rejections don't. Lives apart from
/// `SwarmBridgeTests` so the per-handler matrix there stays focused on
/// reply shape.
@MainActor
final class SwarmBridgeHistoryTests: XCTestCase {
    private var fixture: SwarmBridgeTestFixture!

    private let connectedOrigin = OriginIdentity.from(string: "https://app.uniswap.org")!
    private let testOwner = String(repeating: "ab", count: 20)
    private let testTopic = String(repeating: "aa", count: 32)
    private let testManifestRef = String(repeating: "cd", count: 32)
    private let testContentRef = String(repeating: "11", count: 32)

    override func setUp() async throws {
        fixture = try await SwarmBridgeTestFixture()
    }

    override func tearDown() async throws {
        try await fixture.tearDownAsync()
        fixture = nil
    }

    // MARK: - Helpers

    private func connect() {
        fixture.permissionStore.grant(origin: connectedOrigin.key)
    }

    private func armUsableStamps() {
        fixture.stubs.stamps = [PostageBatch(
            batchID: String(repeating: "ee", count: 32),
            usable: true, usage: 0.1,
            effectiveBytes: 10_000_000, ttlSeconds: 86_400 * 30,
            isMutable: true, depth: 22, amount: "1000", label: nil
        )]
    }

    private func grantConnectedFeedIdentity(name: String = "posts") {
        connect()
        fixture.feedStore.setFeedIdentity(origin: connectedOrigin.key, identityMode: .appScoped)
        fixture.feedStore.upsert(
            origin: connectedOrigin.key, name: name,
            topic: testTopic, owner: testOwner,
            manifestReference: testManifestRef
        )
    }

    private func b64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }

    // MARK: - swarm_publishData

    func testPublishDataApprovedRecordsCompletedHistoryRow() async throws {
        connect()
        armUsableStamps()
        fixture.setNextDecision(.approved)
        fixture.stubs.publishUpload = { _, _, _, _, _ in
            let body = try JSONSerialization.data(
                withJSONObject: ["reference": self.testManifestRef]
            )
            return (body, ["swarm-tag": "42"])
        }
        await fixture.dispatch(
            method: "swarm_publishData",
            params: ["data": "hi", "contentType": "text/plain", "name": "greet.txt"],
            origin: connectedOrigin
        )
        let entries = fixture.publishHistoryStore.entries()
        XCTAssertEqual(entries.count, 1)
        let row = try XCTUnwrap(entries.first)
        XCTAssertEqual(row.kind, .data)
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.name, "greet.txt")
        XCTAssertEqual(row.origin, connectedOrigin.key)
        XCTAssertEqual(row.reference, testManifestRef)
        XCTAssertEqual(row.bytesSize, 2)
        XCTAssertEqual(row.tagUid, 42)
        XCTAssertEqual(row.batchId, String(repeating: "ee", count: 32))
        XCTAssertNotNil(row.completedAt)
        XCTAssertNil(row.errorMessage)
    }

    func testPublishDataDeniedRecordsNothing() async throws {
        // Covers the broader "row written only after approval" guarantee
        // — the user said no, so nothing about this attempt should
        // surface in their published history. (Pre-flight rejections
        // like "not connected" never reach the approval gate either, so
        // they're covered by the same code path.)
        connect()
        armUsableStamps()
        fixture.setNextDecision(.denied)
        await fixture.dispatch(
            method: "swarm_publishData",
            params: ["data": "hi", "contentType": "text/plain"],
            origin: connectedOrigin
        )
        XCTAssertEqual(fixture.publishHistoryStore.entries().count, 0)
    }

    func testPublishDataBeeUnreachableRecordsFailedHistoryRow() async throws {
        connect()
        armUsableStamps()
        fixture.setNextDecision(.approved)
        fixture.stubs.publishUpload = { _, _, _, _, _ in
            throw BeeAPIClient.Error.notRunning
        }
        await fixture.dispatch(
            method: "swarm_publishData",
            params: ["data": "hi", "contentType": "text/plain"],
            origin: connectedOrigin
        )
        let entries = fixture.publishHistoryStore.entries()
        XCTAssertEqual(entries.count, 1)
        let row = try XCTUnwrap(entries.first)
        XCTAssertEqual(row.kind, .data)
        XCTAssertEqual(row.status, .failed)
        XCTAssertNotNil(row.errorMessage)
        XCTAssertNil(row.reference)
        XCTAssertNotNil(row.completedAt)
    }

    // MARK: - swarm_publishFiles

    func testPublishFilesApprovedRecordsCompletedHistoryRow() async throws {
        connect()
        armUsableStamps()
        fixture.setNextDecision(.approved)
        fixture.stubs.publishUpload = { _, _, _, _, _ in
            let body = try JSONSerialization.data(
                withJSONObject: ["reference": self.testManifestRef]
            )
            return (body, ["swarm-tag": "7"])
        }
        await fixture.dispatch(
            method: "swarm_publishFiles",
            params: [
                "files": [["path": "index.html", "bytes": b64("<html/>")]],
                "indexDocument": "index.html",
            ],
            origin: connectedOrigin
        )
        let entries = fixture.publishHistoryStore.entries()
        XCTAssertEqual(entries.count, 1)
        let row = try XCTUnwrap(entries.first)
        XCTAssertEqual(row.kind, .files)
        XCTAssertEqual(row.status, .completed)
        // `indexDocument` falls into `name` for a meaningful UI label.
        XCTAssertEqual(row.name, "index.html")
        XCTAssertEqual(row.reference, testManifestRef)
        XCTAssertEqual(row.tagUid, 7)
        XCTAssertEqual(row.bytesSize, 7)
    }

    // MARK: - swarm_createFeed

    func testCreateFeedApprovedRecordsCompletedHistoryRow() async throws {
        connect()
        armUsableStamps()
        let feedStore = fixture.feedStore
        let connectedKey = connectedOrigin.key
        fixture.setNextDecision(.approved) { _ in
            feedStore.setFeedIdentity(origin: connectedKey, identityMode: .appScoped)
        }
        fixture.stubs.createFeedManifest = { _, _, _ in self.testManifestRef }
        await fixture.dispatch(
            method: "swarm_createFeed",
            params: ["name": "posts"],
            origin: connectedOrigin
        )
        let entries = fixture.publishHistoryStore.entries()
        XCTAssertEqual(entries.count, 1)
        let row = try XCTUnwrap(entries.first)
        XCTAssertEqual(row.kind, .feedCreate)
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.name, "posts")
        XCTAssertEqual(row.reference, testManifestRef)
        // Feed-create has no payload bytes; bytesSize stays nil.
        XCTAssertNil(row.bytesSize)
        XCTAssertNil(row.tagUid)
    }

    func testCreateFeedIdempotentReturnRecordsNothing() async throws {
        // Re-creating an existing (origin, name) hits the SWIP-required
        // idempotent path — no bee call, no approval — so no history row.
        grantConnectedFeedIdentity(name: "existing")
        await fixture.dispatch(
            method: "swarm_createFeed",
            params: ["name": "existing"],
            origin: connectedOrigin
        )
        XCTAssertEqual(fixture.publishHistoryStore.entries().count, 0)
    }

    // MARK: - swarm_updateFeed

    func testUpdateFeedAutoApproveRecordsCompletedHistoryRow() async throws {
        grantConnectedFeedIdentity(name: "posts")
        fixture.permissionStore.setAutoApproveFeeds(origin: connectedOrigin.key, enabled: true)
        armUsableStamps()
        fixture.stubs.readFeedFromService = { _, _, _ in
            throw BeeAPIClient.Error.notFound  // empty feed → next index = 0
        }
        fixture.stubs.uploadSOC = { _, _, _, _, _ in
            (reference: self.testManifestRef, tagUid: 13)
        }
        await fixture.dispatch(
            method: "swarm_updateFeed",
            params: ["feedId": "posts", "reference": testContentRef],
            origin: connectedOrigin
        )
        let entries = fixture.publishHistoryStore.entries()
        XCTAssertEqual(entries.count, 1)
        let row = try XCTUnwrap(entries.first)
        XCTAssertEqual(row.kind, .feedUpdate)
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.name, "posts")
        // Reference recorded is the user-supplied content ref, matching
        // what the bridge replies with — that's what the user uploaded.
        XCTAssertEqual(row.reference, testContentRef)
        XCTAssertEqual(row.tagUid, 13)
    }

    // MARK: - swarm_writeFeedEntry

    func testWriteFeedEntryAutoApproveRecordsCompletedHistoryRow() async throws {
        grantConnectedFeedIdentity(name: "log")
        fixture.permissionStore.setAutoApproveFeeds(origin: connectedOrigin.key, enabled: true)
        armUsableStamps()
        fixture.stubs.readFeedFromService = { _, _, _ in
            BeeAPIClient.FeedReadResult(payload: Data(), index: 3, nextIndex: 4)
        }
        fixture.stubs.uploadSOC = { _, _, _, _, _ in
            (reference: self.testManifestRef, tagUid: 99)
        }
        await fixture.dispatch(
            method: "swarm_writeFeedEntry",
            params: ["name": "log", "data": b64("entry")],
            origin: connectedOrigin
        )
        let entries = fixture.publishHistoryStore.entries()
        XCTAssertEqual(entries.count, 1)
        let row = try XCTUnwrap(entries.first)
        XCTAssertEqual(row.kind, .feedEntry)
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.name, "log")
        // For feed-entry the recorded reference is the SOC chunk
        // address — the unique pointer to *this* entry, not the feed
        // root. Lets the user fetch the chunk back later.
        XCTAssertEqual(row.reference, testManifestRef)
        XCTAssertEqual(row.bytesSize, 5)
        XCTAssertEqual(row.tagUid, 99)
    }

    func testWriteFeedEntryIndexCollisionRecordsFailedHistoryRow() async throws {
        grantConnectedFeedIdentity(name: "log")
        fixture.permissionStore.setAutoApproveFeeds(origin: connectedOrigin.key, enabled: true)
        armUsableStamps()
        fixture.stubs.getChunk = { _ in Data(repeating: 0xff, count: 105) }
        await fixture.dispatch(
            method: "swarm_writeFeedEntry",
            params: [
                "name": "log",
                "data": b64("entry"),
                "index": 5,
            ],
            origin: connectedOrigin
        )
        let entries = fixture.publishHistoryStore.entries()
        XCTAssertEqual(entries.count, 1)
        let row = try XCTUnwrap(entries.first)
        XCTAssertEqual(row.kind, .feedEntry)
        XCTAssertEqual(row.status, .failed)
        XCTAssertNotNil(row.errorMessage)
        XCTAssertNil(row.reference)
    }
}
