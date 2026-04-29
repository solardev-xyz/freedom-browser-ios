import XCTest
@testable import Freedom

@MainActor
final class SwarmBridgeTests: XCTestCase {
    private typealias Reason = SwarmRouter.ErrorPayload.Reason

    private var fixture: SwarmBridgeTestFixture!

    private let connectedOrigin = OriginIdentity.from(string: "https://app.uniswap.org")!
    private let httpOrigin = OriginIdentity.from(string: "http://evil.example.com")!

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

    // MARK: - helpers

    private func connect(_ origin: OriginIdentity? = nil) {
        fixture.permissionStore.grant(origin: (origin ?? connectedOrigin).key)
    }

    /// Sets a single usable batch with capacity for any reasonable
    /// test payload — the typical happy-path stamp setup.
    private func armUsableStamps() {
        fixture.stubs.stamps = [PostageBatch(
            batchID: String(repeating: "ee", count: 32),
            usable: true, usage: 0.1,
            effectiveBytes: 10_000_000, ttlSeconds: 86_400 * 30,
            isMutable: true, depth: 22, amount: "1000", label: nil
        )]
    }

    /// Base64 helper — `Data(s.utf8).base64EncodedString()` reads as
    /// noise inside a params dict.
    private func b64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }

    /// Asserts a single `error` reply with the given code/reason.
    private func assertSingleError(
        code: Int, reason: String? = nil,
        file: StaticString = #file, line: UInt = #line
    ) throws {
        XCTAssertEqual(fixture.recorder.results.count, 0,
                       "unexpected success results", file: file, line: line)
        XCTAssertEqual(fixture.recorder.errors.count, 1,
                       "expected 1 error", file: file, line: line)
        let err = try XCTUnwrap(fixture.recorder.errors.first)
        XCTAssertEqual(err.dict["code"] as? Int, code, file: file, line: line)
        if let reason {
            let data = try XCTUnwrap(err.dict["data"] as? [String: Any],
                                      "missing data dict", file: file, line: line)
            XCTAssertEqual(data["reason"] as? String, reason, file: file, line: line)
        }
    }

    /// Inserts a feed record + identity for the connected origin so
    /// updateFeed / writeFeedEntry tests skip the create-feed prelude.
    private func grantConnectedFeedIdentity(name: String = "posts") {
        connect()
        fixture.feedStore.setFeedIdentity(origin: connectedOrigin.key, identityMode: .appScoped)
        fixture.feedStore.upsert(
            origin: connectedOrigin.key, name: name,
            topic: testTopic, owner: testOwner,
            manifestReference: testManifestRef
        )
    }

    // MARK: - swarm_requestAccess

    func testRequestAccessIneligibleOriginReturns4100() async throws {
        await fixture.dispatch(method: "swarm_requestAccess", origin: httpOrigin)
        try assertSingleError(code: 4100)
    }

    func testRequestAccessConcurrentPendingReturnsResourceUnavailable() async throws {
        // Park a sentinel via a leaked continuation. Resolved at
        // end-of-test so the `withCheckedContinuation` Task finishes.
        fixture.host.onParked = nil  // disarm auto-resolve
        var leakedResolver: ApprovalResolver!
        let leakedTask: Task<ApprovalRequest.Decision, Never> = Task { @MainActor in
            await withCheckedContinuation { (cont: CheckedContinuation<ApprovalRequest.Decision, Never>) in
                leakedResolver = ApprovalResolver(cont)
            }
        }
        await Task.yield()
        fixture.host.pendingSwarmApproval = ApprovalRequest(
            id: UUID(), origin: connectedOrigin,
            kind: .swarmConnect, resolver: leakedResolver
        )

        await fixture.dispatch(method: "swarm_requestAccess", origin: connectedOrigin, id: 2)
        try assertSingleError(code: -32002)

        fixture.host.pendingSwarmApproval?.decide(.denied)
        _ = await leakedTask.value
    }

    func testRequestAccessAlreadyConnectedSkipsSheet() async throws {
        connect()
        await fixture.dispatch(method: "swarm_requestAccess", origin: connectedOrigin)
        XCTAssertEqual(fixture.recorder.errors.count, 0)
        let result = try XCTUnwrap(fixture.recorder.results.first?.value as? [String: Any])
        XCTAssertEqual(result["connected"] as? Bool, true)
        XCTAssertEqual(result["origin"] as? String, connectedOrigin.key)
        XCTAssertEqual(result["capabilities"] as? [String], ["publish"])
        XCTAssertEqual(fixture.recorder.events.count, 0)  // no `connect` event
    }

    func testRequestAccessNewGrantApprovedEmitsConnectAndGrants() async throws {
        fixture.setNextDecision(.approved)
        await fixture.dispatch(method: "swarm_requestAccess", origin: connectedOrigin)
        XCTAssertEqual(fixture.recorder.errors.count, 0)
        let result = try XCTUnwrap(fixture.recorder.results.first?.value as? [String: Any])
        XCTAssertEqual(result["connected"] as? Bool, true)
        XCTAssertTrue(fixture.permissionStore.isConnected(connectedOrigin.key))
        XCTAssertEqual(fixture.recorder.events.count, 1)
        XCTAssertEqual(fixture.recorder.events.first?.name, "connect")
    }

    func testRequestAccessNewGrantDeniedReturns4001() async throws {
        fixture.setNextDecision(.denied)
        await fixture.dispatch(method: "swarm_requestAccess", origin: connectedOrigin)
        try assertSingleError(code: 4001)
        XCTAssertFalse(fixture.permissionStore.isConnected(connectedOrigin.key))
        XCTAssertEqual(fixture.recorder.events.count, 0)
    }

    // MARK: - swarm_publishData

    func testPublishDataNotConnectedReturns4100NotConnected() async throws {
        await fixture.dispatch(
            method: "swarm_publishData",
            params: ["data": "hi", "contentType": "text/plain"],
            origin: connectedOrigin
        )
        try assertSingleError(code: 4100, reason: Reason.notConnected)
    }

    func testPublishDataMissingDataReturnsInvalidParams() async throws {
        connect()
        await fixture.dispatch(
            method: "swarm_publishData",
            params: ["contentType": "text/plain"],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602)
    }

    func testPublishDataMissingContentTypeReturnsInvalidParams() async throws {
        connect()
        await fixture.dispatch(
            method: "swarm_publishData",
            params: ["data": "hi"],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602)
    }

    func testPublishDataPayloadTooLargeReturnsPayloadTooLarge() async throws {
        connect()
        // maxDataBytes default is 10 MiB; build a string exceeding that.
        let oversized = String(repeating: "x", count: 11 * 1024 * 1024)
        await fixture.dispatch(
            method: "swarm_publishData",
            params: ["data": oversized, "contentType": "text/plain"],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602, reason: Reason.payloadTooLarge)
    }

    func testPublishDataNoUsableStampsReturns4900() async throws {
        connect()
        // No stamps queued → caps pass (no node-failure reason set), but
        // batch selection finds nothing and short-circuits with 4900.
        await fixture.dispatch(
            method: "swarm_publishData",
            params: ["data": "hi", "contentType": "text/plain"],
            origin: connectedOrigin
        )
        try assertSingleError(code: 4900, reason: Reason.noUsableStamps)
    }

    func testPublishDataNodeUltraLightReturns4900() async throws {
        connect()
        // Router caps gate fires before stamp selection.
        fixture.stubs.routerNodeReason = Reason.ultraLightMode
        await fixture.dispatch(
            method: "swarm_publishData",
            params: ["data": "hi", "contentType": "text/plain"],
            origin: connectedOrigin
        )
        try assertSingleError(code: 4900, reason: Reason.ultraLightMode)
    }

    func testPublishDataDeniedReturns4001() async throws {
        connect()
        armUsableStamps()
        fixture.setNextDecision(.denied)
        await fixture.dispatch(
            method: "swarm_publishData",
            params: ["data": "hi", "contentType": "text/plain"],
            origin: connectedOrigin
        )
        try assertSingleError(code: 4001)
    }

    func testPublishDataApprovedUploadsAndReplies() async throws {
        connect()
        armUsableStamps()
        fixture.setNextDecision(.approved)
        var capturedPath: String?
        var capturedContentType: String?
        var capturedHeaders: [String: String] = [:]
        fixture.stubs.publishUpload = { path, _, ct, headers, _ in
            capturedPath = path
            capturedContentType = ct
            capturedHeaders = headers
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
        XCTAssertEqual(capturedPath, "/bzz")
        XCTAssertEqual(capturedContentType, "text/plain")
        XCTAssertEqual(capturedHeaders["Swarm-Pin"], "true")
        XCTAssertEqual(capturedHeaders["Swarm-Deferred-Upload"], "true")
        let result = try XCTUnwrap(fixture.recorder.results.first?.value as? [String: Any])
        XCTAssertEqual(result["reference"] as? String, testManifestRef)
        XCTAssertEqual(result["bzzUrl"] as? String, "bzz://\(testManifestRef)")
        // Tag-ownership recorded for cross-origin defense.
        XCTAssertEqual(fixture.tagOwnership.owner(of: 42), connectedOrigin.key)
    }

    func testPublishDataAutoApproveSkipsSheet() async throws {
        connect()
        fixture.permissionStore.setAutoApprovePublish(origin: connectedOrigin.key, enabled: true)
        armUsableStamps()
        // No setNextDecision — sheet must not show; XCTFail in onParked
        // would catch a stray park.
        fixture.stubs.publishUpload = { _, _, _, _, _ in
            let body = try JSONSerialization.data(
                withJSONObject: ["reference": self.testManifestRef]
            )
            return (body, [:])
        }
        await fixture.dispatch(
            method: "swarm_publishData",
            params: ["data": "hi", "contentType": "text/plain"],
            origin: connectedOrigin
        )
        XCTAssertEqual(fixture.recorder.errors.count, 0)
        XCTAssertNotNil(fixture.recorder.results.first)
    }

    func testPublishDataBeeUnreachableReturns4900NodeStopped() async throws {
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
        try assertSingleError(code: 4900, reason: Reason.nodeStopped)
    }

    // MARK: - swarm_publishFiles

    private func file(_ path: String, bytes: Data = Data("hi".utf8)) -> [String: Any] {
        ["path": path, "bytes": bytes.base64EncodedString()]
    }

    func testPublishFilesEmptyArrayInvalid() async throws {
        connect()
        await fixture.dispatch(
            method: "swarm_publishFiles",
            params: ["files": []],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602)
    }

    func testPublishFilesDuplicatePathsInvalid() async throws {
        connect()
        await fixture.dispatch(
            method: "swarm_publishFiles",
            params: ["files": [file("a.txt"), file("a.txt")]],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602)
    }

    func testPublishFilesLeadingSlashInvalid() async throws {
        connect()
        await fixture.dispatch(
            method: "swarm_publishFiles",
            params: ["files": [file("/foo.txt")]],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602)
    }

    func testPublishFilesBackslashInvalid() async throws {
        connect()
        await fixture.dispatch(
            method: "swarm_publishFiles",
            params: ["files": [file("a\\b.txt")]],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602)
    }

    func testPublishFilesControlCharInvalid() async throws {
        connect()
        await fixture.dispatch(
            method: "swarm_publishFiles",
            params: ["files": [file("a\u{01}b.txt")]],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602)
    }

    func testPublishFilesDotSegmentInvalid() async throws {
        connect()
        await fixture.dispatch(
            method: "swarm_publishFiles",
            params: ["files": [file("./a.txt")]],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602)
    }

    func testPublishFilesPathOver100UTF8BytesInvalid() async throws {
        connect()
        // 51 × 2-byte UTF-8 chars = 102 bytes — over the USTAR limit.
        let longPath = String(repeating: "é", count: 51)
        await fixture.dispatch(
            method: "swarm_publishFiles",
            params: ["files": [file(longPath)]],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602)
    }

    func testPublishFilesIndexDocumentNotInFilesInvalid() async throws {
        connect()
        await fixture.dispatch(
            method: "swarm_publishFiles",
            params: [
                "files": [file("a.txt")],
                "indexDocument": "missing.txt",
            ],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602)
    }

    func testPublishFilesApprovedUploadsAndReplies() async throws {
        connect()
        armUsableStamps()
        fixture.setNextDecision(.approved)
        var capturedHeaders: [String: String] = [:]
        var capturedContentType: String?
        fixture.stubs.publishUpload = { _, _, ct, headers, _ in
            capturedContentType = ct
            capturedHeaders = headers
            let body = try JSONSerialization.data(
                withJSONObject: ["reference": self.testManifestRef]
            )
            return (body, ["swarm-tag": "7"])
        }
        await fixture.dispatch(
            method: "swarm_publishFiles",
            params: [
                "files": [file("index.html"), file("a.txt")],
                "indexDocument": "index.html",
            ],
            origin: connectedOrigin
        )
        XCTAssertEqual(capturedContentType, "application/x-tar")
        XCTAssertEqual(capturedHeaders["Swarm-Collection"], "true")
        XCTAssertEqual(capturedHeaders["Swarm-Index-Document"], "index.html")
        let result = try XCTUnwrap(fixture.recorder.results.first?.value as? [String: Any])
        XCTAssertEqual(result["reference"] as? String, testManifestRef)
        XCTAssertEqual(result["tagUid"] as? Int, 7)
    }

    // MARK: - swarm_getUploadStatus

    func testGetUploadStatusIneligibleOriginReturns4100() async throws {
        await fixture.dispatch(
            method: "swarm_getUploadStatus",
            params: ["tagUid": 42],
            origin: httpOrigin
        )
        try assertSingleError(code: 4100)
    }

    func testGetUploadStatusInvalidTagUidNonIntReturnsInvalidParams() async throws {
        await fixture.dispatch(
            method: "swarm_getUploadStatus",
            params: ["tagUid": "not-an-int"],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602)
    }

    func testGetUploadStatusNegativeTagUidReturnsInvalidParams() async throws {
        await fixture.dispatch(
            method: "swarm_getUploadStatus",
            params: ["tagUid": -5],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602)
    }

    func testGetUploadStatusUnownedTagReturns4100() async throws {
        await fixture.dispatch(
            method: "swarm_getUploadStatus",
            params: ["tagUid": 42],
            origin: connectedOrigin
        )
        try assertSingleError(code: 4100)
    }

    func testGetUploadStatusBee404ForgetsTagAndReturns4100() async throws {
        fixture.tagOwnership.record(tag: 42, origin: connectedOrigin.key)
        fixture.stubs.getTag = { _ in throw BeeAPIClient.Error.notFound }
        await fixture.dispatch(
            method: "swarm_getUploadStatus",
            params: ["tagUid": 42],
            origin: connectedOrigin
        )
        try assertSingleError(code: 4100)
        // Bee evicted the tag; bridge drops the local record so the next
        // call short-circuits without bee round-trip.
        XCTAssertNil(fixture.tagOwnership.owner(of: 42))
    }

    func testGetUploadStatusBeeUnreachableReturns4900() async throws {
        fixture.tagOwnership.record(tag: 42, origin: connectedOrigin.key)
        fixture.stubs.getTag = { _ in throw BeeAPIClient.Error.notRunning }
        await fixture.dispatch(
            method: "swarm_getUploadStatus",
            params: ["tagUid": 42],
            origin: connectedOrigin
        )
        try assertSingleError(code: 4900, reason: Reason.nodeStopped)
    }

    func testGetUploadStatusHappyPathReturnsAllFields() async throws {
        fixture.tagOwnership.record(tag: 42, origin: connectedOrigin.key)
        fixture.stubs.getTag = { _ in
            BeeAPIClient.TagResponse(
                uid: 42, split: 10, seen: 5, stored: 7, sent: 3, synced: 2
            )
        }
        await fixture.dispatch(
            method: "swarm_getUploadStatus",
            params: ["tagUid": 42],
            origin: connectedOrigin
        )
        let result = try XCTUnwrap(fixture.recorder.results.first?.value as? [String: Any])
        XCTAssertEqual(result["tagUid"] as? Int, 42)
        XCTAssertEqual(result["split"] as? Int, 10)
        XCTAssertEqual(result["seen"] as? Int, 5)
        XCTAssertEqual(result["stored"] as? Int, 7)
        XCTAssertEqual(result["sent"] as? Int, 3)
        XCTAssertEqual(result["synced"] as? Int, 2)
        XCTAssertEqual(result["progress"] as? Int, 30)  // 3/10
        XCTAssertEqual(result["done"] as? Bool, false)
        // Not done → ownership preserved.
        XCTAssertEqual(fixture.tagOwnership.owner(of: 42), connectedOrigin.key)
    }

    func testGetUploadStatusDoneTagDropsOwnership() async throws {
        fixture.tagOwnership.record(tag: 42, origin: connectedOrigin.key)
        fixture.stubs.getTag = { _ in
            BeeAPIClient.TagResponse(
                uid: 42, split: 10, seen: 10, stored: 10, sent: 10, synced: 10
            )
        }
        await fixture.dispatch(
            method: "swarm_getUploadStatus",
            params: ["tagUid": 42],
            origin: connectedOrigin
        )
        let result = try XCTUnwrap(fixture.recorder.results.first?.value as? [String: Any])
        XCTAssertEqual(result["done"] as? Bool, true)
        XCTAssertNil(fixture.tagOwnership.owner(of: 42))
    }

    // MARK: - swarm_createFeed

    func testCreateFeedNotConnectedReturns4100NotConnected() async throws {
        await fixture.dispatch(
            method: "swarm_createFeed",
            params: ["name": "posts"],
            origin: connectedOrigin
        )
        try assertSingleError(code: 4100, reason: Reason.notConnected)
    }

    func testCreateFeedEmptyNameReturnsInvalidFeedName() async throws {
        connect()
        await fixture.dispatch(
            method: "swarm_createFeed",
            params: ["name": ""],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602, reason: Reason.invalidFeedName)
    }

    func testCreateFeedNameWithSlashInvalid() async throws {
        connect()
        await fixture.dispatch(
            method: "swarm_createFeed",
            params: ["name": "a/b"],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602, reason: Reason.invalidFeedName)
    }

    func testCreateFeedNameTooLongInvalid() async throws {
        connect()
        let longName = String(repeating: "a", count: 65)
        await fixture.dispatch(
            method: "swarm_createFeed",
            params: ["name": longName],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602, reason: Reason.invalidFeedName)
    }

    func testCreateFeedIdempotentRecreateNoSheet() async throws {
        grantConnectedFeedIdentity(name: "posts")
        // No setNextDecision queued and no createFeedManifest stub —
        // either being touched would XCTFail in the fixture defaults.
        await fixture.dispatch(
            method: "swarm_createFeed",
            params: ["name": "posts"],
            origin: connectedOrigin
        )
        let result = try XCTUnwrap(fixture.recorder.results.first?.value as? [String: Any])
        XCTAssertEqual(result["feedId"] as? String, "posts")
        XCTAssertEqual(result["topic"] as? String, testTopic)
        XCTAssertEqual(result["owner"] as? String, testOwner)
        XCTAssertEqual(result["manifestReference"] as? String, testManifestRef)
        XCTAssertEqual(result["identityMode"] as? String, "app-scoped")
    }

    func testCreateFeedFirstGrantDeniedReturns4001() async throws {
        connect()
        armUsableStamps()
        fixture.setNextDecision(.denied)
        await fixture.dispatch(
            method: "swarm_createFeed",
            params: ["name": "posts"],
            origin: connectedOrigin
        )
        try assertSingleError(code: 4001)
        XCTAssertNil(fixture.feedStore.feedIdentity(origin: connectedOrigin.key))
    }

    func testCreateFeedFirstGrantApprovedAppScopedPersistsAndCallsBee() async throws {
        connect()
        armUsableStamps()
        // Sheet's approve() writes the SwarmFeedIdentity row before
        // resolving the continuation — model that as a side-effect.
        let feedStore = fixture.feedStore
        let connectedKey = connectedOrigin.key
        fixture.setNextDecision(.approved) { _ in
            feedStore.setFeedIdentity(origin: connectedKey, identityMode: .appScoped)
        }
        var capturedOwner: String?
        var capturedTopic: String?
        fixture.stubs.createFeedManifest = { owner, topic, _ in
            capturedOwner = owner
            capturedTopic = topic
            return self.testManifestRef
        }
        await fixture.dispatch(
            method: "swarm_createFeed",
            params: ["name": "posts"],
            origin: connectedOrigin
        )
        XCTAssertEqual(fixture.recorder.errors.count, 0)
        XCTAssertNotNil(capturedOwner, "createFeedManifest should be called")
        XCTAssertNotNil(capturedTopic)
        let result = try XCTUnwrap(fixture.recorder.results.first?.value as? [String: Any])
        XCTAssertEqual(result["feedId"] as? String, "posts")
        XCTAssertEqual(result["identityMode"] as? String, "app-scoped")
        XCTAssertNotNil(fixture.feedStore.lookup(origin: connectedKey, name: "posts"))
        let identity = try XCTUnwrap(fixture.feedStore.feedIdentity(origin: connectedKey))
        XCTAssertEqual(identity.publisherKeyIndex, 0)
    }

    func testCreateFeedSubsequentGrantAutoApproveSkipsSheet() async throws {
        grantConnectedFeedIdentity(name: "existing")
        fixture.permissionStore.setAutoApproveFeeds(origin: connectedOrigin.key, enabled: true)
        armUsableStamps()
        fixture.stubs.createFeedManifest = { _, _, _ in self.testManifestRef }
        // No setNextDecision — sheet must not show.
        await fixture.dispatch(
            method: "swarm_createFeed",
            params: ["name": "another-feed"],
            origin: connectedOrigin
        )
        XCTAssertEqual(fixture.recorder.errors.count, 0)
        XCTAssertNotNil(fixture.feedStore.lookup(origin: connectedOrigin.key, name: "another-feed"))
    }

    func testCreateFeedBeeUnreachableReturns4900() async throws {
        grantConnectedFeedIdentity(name: "existing")
        fixture.permissionStore.setAutoApproveFeeds(origin: connectedOrigin.key, enabled: true)
        armUsableStamps()
        fixture.stubs.createFeedManifest = { _, _, _ in
            throw BeeAPIClient.Error.notRunning
        }
        await fixture.dispatch(
            method: "swarm_createFeed",
            params: ["name": "new-feed"],
            origin: connectedOrigin
        )
        try assertSingleError(code: 4900, reason: Reason.nodeStopped)
    }

    // MARK: - swarm_updateFeed

    func testUpdateFeedNotConnectedReturns4100NotConnected() async throws {
        await fixture.dispatch(
            method: "swarm_updateFeed",
            params: ["feedId": "posts", "reference": testContentRef],
            origin: connectedOrigin
        )
        try assertSingleError(code: 4100, reason: Reason.notConnected)
    }

    func testUpdateFeedInvalidFeedIdReturnsInvalidFeedName() async throws {
        connect()
        await fixture.dispatch(
            method: "swarm_updateFeed",
            params: ["feedId": "", "reference": testContentRef],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602, reason: Reason.invalidFeedName)
    }

    func testUpdateFeedInvalidReferenceReturnsInvalidParams() async throws {
        connect()
        await fixture.dispatch(
            method: "swarm_updateFeed",
            params: ["feedId": "posts", "reference": "not-hex"],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602)
    }

    func testUpdateFeedFeedNotFoundReturnsFeedNotFound() async throws {
        connect()
        await fixture.dispatch(
            method: "swarm_updateFeed",
            params: ["feedId": "ghost", "reference": testContentRef],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602, reason: Reason.feedNotFound)
    }

    func testUpdateFeedAutoApproveCallsBeeAndUpdatesStore() async throws {
        grantConnectedFeedIdentity(name: "posts")
        fixture.permissionStore.setAutoApproveFeeds(origin: connectedOrigin.key, enabled: true)
        armUsableStamps()
        fixture.stubs.readFeedFromService = { _, _, _ in
            throw BeeAPIClient.Error.notFound  // empty feed → next index = 0
        }
        var capturedOwner: String?
        fixture.stubs.uploadSOC = { o, _, _, _, _ in
            capturedOwner = o
            return (reference: self.testManifestRef, tagUid: 13)
        }
        await fixture.dispatch(
            method: "swarm_updateFeed",
            params: ["feedId": "posts", "reference": testContentRef],
            origin: connectedOrigin
        )
        XCTAssertEqual(fixture.recorder.errors.count, 0)
        XCTAssertEqual(capturedOwner, testOwner)
        let result = try XCTUnwrap(fixture.recorder.results.first?.value as? [String: Any])
        XCTAssertEqual(result["feedId"] as? String, "posts")
        XCTAssertEqual(result["reference"] as? String, testContentRef)
        XCTAssertEqual(result["index"] as? Int, 0)
        XCTAssertEqual(fixture.tagOwnership.owner(of: 13), connectedOrigin.key)
        let record = try XCTUnwrap(fixture.feedStore.lookup(origin: connectedOrigin.key, name: "posts"))
        XCTAssertEqual(record.lastReference, testContentRef)
    }

    func testUpdateFeedDeniedReturns4001() async throws {
        grantConnectedFeedIdentity(name: "posts")
        armUsableStamps()
        fixture.setNextDecision(.denied)
        await fixture.dispatch(
            method: "swarm_updateFeed",
            params: ["feedId": "posts", "reference": testContentRef],
            origin: connectedOrigin
        )
        try assertSingleError(code: 4001)
    }

    func testUpdateFeedBeeUnreachableReturns4900() async throws {
        grantConnectedFeedIdentity(name: "posts")
        fixture.permissionStore.setAutoApproveFeeds(origin: connectedOrigin.key, enabled: true)
        armUsableStamps()
        fixture.stubs.readFeedFromService = { _, _, _ in
            throw BeeAPIClient.Error.notRunning
        }
        await fixture.dispatch(
            method: "swarm_updateFeed",
            params: ["feedId": "posts", "reference": testContentRef],
            origin: connectedOrigin
        )
        try assertSingleError(code: 4900, reason: Reason.nodeStopped)
    }

    // MARK: - swarm_writeFeedEntry

    func testWriteFeedEntryNotConnectedReturns4100() async throws {
        await fixture.dispatch(
            method: "swarm_writeFeedEntry",
            params: ["name": "posts", "data": b64("hi")],
            origin: connectedOrigin
        )
        try assertSingleError(code: 4100, reason: Reason.notConnected)
    }

    func testWriteFeedEntryInvalidNameReturnsInvalidFeedName() async throws {
        connect()
        await fixture.dispatch(
            method: "swarm_writeFeedEntry",
            params: ["name": "", "data": b64("hi")],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602, reason: Reason.invalidFeedName)
    }

    func testWriteFeedEntryEmptyDataReturnsInvalidParams() async throws {
        connect()
        await fixture.dispatch(
            method: "swarm_writeFeedEntry",
            params: ["name": "posts", "data": ""],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602)
    }

    func testWriteFeedEntryNonBase64DataReturnsInvalidParams() async throws {
        connect()
        await fixture.dispatch(
            method: "swarm_writeFeedEntry",
            params: ["name": "posts", "data": "!!!not-base64!!!"],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602)
    }

    func testWriteFeedEntryPayloadTooLargeReturnsPayloadTooLarge() async throws {
        connect()
        // maxDataBytes is 10 MiB; build a base64-encoded payload whose
        // decoded size clearly exceeds it. Mirrors the publishData
        // payload-too-large test.
        let oversized = Data(repeating: 0x61, count: 11 * 1024 * 1024)
            .base64EncodedString()
        await fixture.dispatch(
            method: "swarm_writeFeedEntry",
            params: ["name": "posts", "data": oversized],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602, reason: Reason.payloadTooLarge)
    }

    func testWriteFeedEntryNegativeIndexReturnsInvalidParams() async throws {
        connect()
        await fixture.dispatch(
            method: "swarm_writeFeedEntry",
            params: [
                "name": "posts",
                "data": b64("hi"),
                "index": -1,
            ],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602)
    }

    func testWriteFeedEntryFeedNotFoundReturnsFeedNotFound() async throws {
        connect()
        await fixture.dispatch(
            method: "swarm_writeFeedEntry",
            params: ["name": "ghost", "data": b64("hi")],
            origin: connectedOrigin
        )
        try assertSingleError(code: -32602, reason: Reason.feedNotFound)
    }

    func testWriteFeedEntryAutoApproveAppendsAtNextIndex() async throws {
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
        XCTAssertEqual(fixture.recorder.errors.count, 0)
        let result = try XCTUnwrap(fixture.recorder.results.first?.value as? [String: Any])
        XCTAssertEqual(result["index"] as? Int, 4)
        XCTAssertEqual(fixture.tagOwnership.owner(of: 99), connectedOrigin.key)
    }

    func testWriteFeedEntryExplicitIndexCollisionReturnsIndexAlreadyExists() async throws {
        grantConnectedFeedIdentity(name: "log")
        fixture.permissionStore.setAutoApproveFeeds(origin: connectedOrigin.key, enabled: true)
        armUsableStamps()
        // Explicit-index path probes via getChunk; non-empty response =
        // collision → indexAlreadyExists from the service.
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
        try assertSingleError(code: -32602, reason: Reason.indexAlreadyExists)
    }

    func testWriteFeedEntryDeniedReturns4001() async throws {
        grantConnectedFeedIdentity(name: "log")
        armUsableStamps()
        fixture.setNextDecision(.denied)
        await fixture.dispatch(
            method: "swarm_writeFeedEntry",
            params: ["name": "log", "data": b64("entry")],
            origin: connectedOrigin
        )
        try assertSingleError(code: 4001)
    }
}
