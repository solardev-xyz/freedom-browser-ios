import SwiftData
import XCTest
@testable import Freedom

/// `SwarmManifestStore` against real `SwarmPermissionStore` /
/// `SwarmFeedStore` rows — the projection contract desktop's
/// `permission-manifests.test.js` pins down.
@MainActor
final class SwarmManifestStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var permissions: SwarmPermissionStore!
    private var feeds: SwarmFeedStore!
    private var store: SwarmManifestStore!
    private var fileURL: URL!
    private var discoveries: [SwarmManifestDiscovery] = []
    private var discoverCalls = 0
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    /// Keeps `@MainActor` fixtures alive until the case is torn down —
    /// deallocating one synchronously inside a test body aborts.
    private var keep: [AnyObject] = []

    private let ref = String(repeating: "ab", count: 32)
    private var origin: OriginIdentity { OriginIdentity.from(string: "bzz://\(ref)")! }
    private var page: URL { URL(string: "bzz://\(ref)/")! }

    override func setUp() async throws {
        container = try inMemoryContainer(for: SwarmPermission.self, SwarmFeedRecord.self, SwarmFeedIdentity.self)
        permissions = SwarmPermissionStore(context: container.mainContext)
        feeds = SwarmFeedStore(context: container.mainContext)
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("manifests-\(UUID().uuidString).json")
        store = makeStore()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func makeStore() -> SwarmManifestStore {
        let store = SwarmManifestStore(
            fileURL: fileURL, permissionStore: permissions, feedStore: feeds,
            discover: { [unowned self] _ in
                discoverCalls += 1
                return discoveries.isEmpty ? .absent : discoveries.removeFirst()
            },
            now: { [unowned self] in now }
        )
        keep.append(store)
        return store
    }

    private func manifest(_ capabilities: [SwarmManifestCapability: String], name: String = "Notes") -> SwarmManifestDiscovery {
        let manifest = SwarmManifest(schema: SwarmManifest.schema, name: name, description: "Notes on Swarm", capabilities: capabilities)
        return .found(manifest: manifest, rawHash: SwarmManifest.sha256Hex(Data("\(name)-\(capabilities)".utf8)))
    }

    private func consent(eager: Bool = true) async throws -> (token: String, model: SwarmManifestConsentModel) {
        let result = await store.check(origin: origin, committedURL: page, eager: eager)
        guard case .consent(let token, let model) = result else {
            throw XCTSkip("expected consent, got \(result)")
        }
        return (token, model)
    }

    // MARK: - Discovery gating

    func testNonEagerCheckWithoutRecordIsLegacyAndNeverFetches() async {
        discoveries = [manifest([.publish: "x"])]
        let result = await store.check(origin: origin, committedURL: page, eager: false)
        XCTAssertEqual(result, .legacy)
        XCTAssertEqual(discoverCalls, 0)
    }

    func testNonBzzOriginsAreLegacyWithoutFetching() async {
        let https = OriginIdentity.from(string: "https://app.example")!
        let result = await store.check(origin: https, committedURL: URL(string: "https://app.example/")!, eager: true)
        XCTAssertEqual(result, .legacy)
        XCTAssertEqual(discoverCalls, 0)
    }

    func testAbsentManifestIsLegacy() async {
        discoveries = [.absent]
        let result = await store.check(origin: origin, committedURL: page, eager: true)
        XCTAssertEqual(result, .legacy)
        XCTAssertNil(store.record(for: origin.key))
    }

    // MARK: - Consent + projection

    func testAllowProjectsEveryDeclaredCapability() async throws {
        discoveries = [manifest([.publish: "Save notes", .feeds: "List notes", .messaging: "Sync"])]
        let (token, model) = try await consent()
        XCTAssertEqual(model.changed.map(\.capability), [.publish, .feeds, .messaging])
        XCTAssertEqual(model.changed[0].why, "Save notes")
        XCTAssertTrue(model.createsIdentity)
        XCTAssertFalse(model.isUpdate)
        XCTAssertFalse(permissions.isConnected(origin.key))

        let decision = try store.decide(token: token, outcome: .allow)
        XCTAssertEqual(decision, .init(allowed: true, mode: .allow))
        XCTAssertTrue(permissions.isConnected(origin.key))
        XCTAssertTrue(permissions.isAutoApprovePublish(origin: origin.key))
        XCTAssertTrue(permissions.isAutoApproveFeeds(origin: origin.key))
        XCTAssertTrue(permissions.hasMessagingGrant(origin.key))
        XCTAssertTrue(permissions.isAutoApproveMessaging(origin: origin.key))
        XCTAssertEqual(feeds.feedIdentity(origin: origin.key)?.identityMode, .appScoped)

        let record = try XCTUnwrap(store.record(for: origin.key))
        XCTAssertEqual(record.acknowledged["publish"]?.decision, .managed)
        XCTAssertEqual(record.acknowledged["feeds"]?.whyShown, "List notes")
        // Every capability co-owns the connection; only the last one to
        // go withdraws it.
        XCTAssertEqual(record.managed["connection"], ["publish", "feeds", "messaging"])
        XCTAssertEqual(record.managed["autoApprove.feeds"], ["feeds"])
        XCTAssertEqual(record.receipts.count, 1)
        XCTAssertEqual(record.receipts[0].rows.map(\.capability), ["publish", "feeds", "messaging"])
        XCTAssertEqual(record.revision, 1)

        // Everything acknowledged: the next refresh is silent.
        discoveries = [manifest([.publish: "Save notes", .feeds: "List notes", .messaging: "Sync"])]
        let again = await store.check(origin: origin, committedURL: page, eager: false)
        XCTAssertEqual(again, .ready)
    }

    func testIndividualConnectsWithoutBatchFlags() async throws {
        discoveries = [manifest([.publish: "x", .feeds: "y"])]
        let (token, _) = try await consent()
        let decision = try store.decide(token: token, outcome: .individual)
        XCTAssertEqual(decision, .init(allowed: true, mode: .individual))
        XCTAssertTrue(permissions.isConnected(origin.key))
        XCTAssertFalse(permissions.isAutoApprovePublish(origin: origin.key))
        XCTAssertNil(feeds.feedIdentity(origin: origin.key))
        let record = try XCTUnwrap(store.record(for: origin.key))
        XCTAssertEqual(record.acknowledged["publish"]?.decision, .individual)
        XCTAssertEqual(record.detached["connection"], true)
        XCTAssertTrue(record.managed.isEmpty)
    }

    func testDeniedFirstContactLeavesNoTrace() async throws {
        discoveries = [manifest([.publish: "x"])]
        let (token, _) = try await consent()
        XCTAssertNotNil(store.record(for: origin.key))
        let decision = try store.decide(token: token, outcome: .deny)
        XCTAssertEqual(decision, .init(allowed: false, mode: .deny))
        XCTAssertNil(store.record(for: origin.key))
        XCTAssertFalse(permissions.isConnected(origin.key))
    }

    func testExistingUserGrantsAreAcknowledgedSilently() async {
        permissions.grant(origin: origin.key)
        permissions.setAutoApprovePublish(origin: origin.key, enabled: true)
        discoveries = [manifest([.publish: "x"])]
        let result = await store.check(origin: origin, committedURL: page, eager: true)
        XCTAssertEqual(result, .ready)
        XCTAssertEqual(store.record(for: origin.key)?.acknowledged["publish"]?.source, "existing-grant")
        XCTAssertTrue(store.record(for: origin.key)?.managed.isEmpty ?? false)
    }

    // MARK: - Diffs

    func testRemovedCapabilityWithdrawsOnlyWhatItOwned() async throws {
        discoveries = [manifest([.publish: "x", .feeds: "y"])]
        let (token, _) = try await consent()
        try store.decide(token: token, outcome: .allow)

        discoveries = [manifest([.feeds: "y"])]
        let result = await store.check(origin: origin, committedURL: page, eager: false)
        XCTAssertEqual(result, .ready)
        XCTAssertFalse(permissions.isAutoApprovePublish(origin: origin.key))
        // Feeds still owns the connection and its own flags.
        XCTAssertTrue(permissions.isConnected(origin.key))
        XCTAssertTrue(permissions.isAutoApproveFeeds(origin: origin.key))
        let record = try XCTUnwrap(store.record(for: origin.key))
        XCTAssertNil(record.acknowledged["publish"])
        XCTAssertEqual(record.managed["connection"], ["feeds"])
        XCTAssertEqual(record.revision, 2)
    }

    func testAddedCapabilityAsksAgainAsAnUpdate() async throws {
        discoveries = [manifest([.publish: "x"])]
        let (token, _) = try await consent()
        try store.decide(token: token, outcome: .allow)

        discoveries = [manifest([.publish: "x", .messaging: "chat"])]
        let (_, model) = try await consent(eager: false)
        XCTAssertTrue(model.isUpdate)
        XCTAssertEqual(model.changed.map(\.capability), [.messaging])
        XCTAssertTrue(model.removed.isEmpty)
    }

    func testDefinitiveDisappearancePrunesButKeepsIdentity() async throws {
        discoveries = [manifest([.feeds: "y"])]
        let (token, _) = try await consent()
        try store.decide(token: token, outcome: .allow)
        XCTAssertNotNil(feeds.feedIdentity(origin: origin.key))

        discoveries = [.absent]
        let result = await store.check(origin: origin, committedURL: page, eager: false)
        XCTAssertEqual(result, .legacy)
        XCTAssertNil(store.record(for: origin.key))
        XCTAssertFalse(permissions.isConnected(origin.key))
        XCTAssertNotNil(feeds.feedIdentity(origin: origin.key))
    }

    func testTransientFailureKeepsGrantsAndBacksOff() async throws {
        discoveries = [manifest([.publish: "x"])]
        let (token, _) = try await consent()
        try store.decide(token: token, outcome: .allow)

        discoveries = [.unresolved]
        let first = await store.check(origin: origin, committedURL: page, eager: false)
        XCTAssertEqual(first, .unresolved(retryAt: now.addingTimeInterval(2)))
        XCTAssertTrue(permissions.isAutoApprovePublish(origin: origin.key))
        XCTAssertNotNil(store.record(for: origin.key))

        // Inside the window: no fetch, same answer.
        let calls = discoverCalls
        now = now.addingTimeInterval(1)
        let second = await store.check(origin: origin, committedURL: page, eager: false)
        XCTAssertEqual(second, .unresolved(retryAt: now.addingTimeInterval(1)))
        XCTAssertEqual(discoverCalls, calls)

        // After it: fetch again, and the next failure waits longer.
        now = now.addingTimeInterval(2)
        discoveries = [.unresolved]
        let third = await store.check(origin: origin, committedURL: page, eager: false)
        XCTAssertEqual(third, .unresolved(retryAt: now.addingTimeInterval(10)))
    }

    func testUnresolvedWithoutRecordIsLegacy() async {
        discoveries = [.unresolved]
        let result = await store.check(origin: origin, committedURL: page, eager: true)
        XCTAssertEqual(result, .legacy)
    }

    // MARK: - Tokens

    func testTwoTabsShareOneConsentAndReplayTheDecision() async throws {
        discoveries = [manifest([.publish: "x"]), manifest([.publish: "x"])]
        let (first, _) = try await consent()
        let (second, _) = try await consent()
        XCTAssertEqual(first, second)
        try store.decide(token: first, outcome: .allow)
        XCTAssertEqual(try store.decide(token: second, outcome: .deny), .init(allowed: true, mode: .allow))
    }

    func testChangedManifestInvalidatesOutstandingConsent() async throws {
        discoveries = [manifest([.publish: "x"]), manifest([.publish: "x", .feeds: "y"])]
        let (stale, _) = try await consent()
        let (fresh, _) = try await consent()
        XCTAssertNotEqual(stale, fresh)
        XCTAssertThrowsError(try store.decide(token: stale, outcome: .allow)) { error in
            XCTAssertEqual(error as? SwarmManifestStore.DecisionError, .stale)
        }
        XCTAssertNoThrow(try store.decide(token: fresh, outcome: .allow))
    }

    func testExpiredTokenIsRejected() async throws {
        discoveries = [manifest([.publish: "x"])]
        let (token, _) = try await consent()
        now = now.addingTimeInterval(SwarmManifestStore.tokenTTL + 1)
        XCTAssertThrowsError(try store.decide(token: token, outcome: .allow)) { error in
            XCTAssertEqual(error as? SwarmManifestStore.DecisionError, .expired)
        }
    }

    // MARK: - Settings + manual changes

    func testUseIndividualDropsManagedFlagsButKeepsConnection() async throws {
        discoveries = [manifest([.publish: "x"])]
        let (token, _) = try await consent()
        try store.decide(token: token, outcome: .allow)
        XCTAssertTrue(store.useIndividual(origin: origin.key, capability: .publish))
        XCTAssertTrue(permissions.isConnected(origin.key))
        XCTAssertFalse(permissions.isAutoApprovePublish(origin: origin.key))
        let record = try XCTUnwrap(store.record(for: origin.key))
        XCTAssertEqual(record.acknowledged["publish"]?.decision, .individual)
        XCTAssertEqual(record.detached["connection"], true)
        XCTAssertFalse(store.useIndividual(origin: origin.key, capability: .feeds))
    }

    func testDisconnectForgetsTheApp() async throws {
        discoveries = [manifest([.publish: "x"])]
        let (token, _) = try await consent()
        try store.decide(token: token, outcome: .allow)
        store.disconnect(origin: origin.key)
        XCTAssertNil(store.record(for: origin.key))
        XCTAssertFalse(permissions.isConnected(origin.key))
    }

    func testManualToggleDetachesSoTheManifestCannotResurrectIt() async throws {
        discoveries = [manifest([.publish: "x"])]
        let (token, _) = try await consent()
        try store.decide(token: token, outcome: .allow)

        // The user turns the flag off by hand (default source: user).
        permissions.setAutoApprovePublish(origin: origin.key, enabled: false)
        XCTAssertEqual(store.record(for: origin.key)?.detached["autoApprove.publish"], true)
        XCTAssertNil(store.record(for: origin.key)?.managed["autoApprove.publish"])

        discoveries = [manifest([.publish: "x"])]
        let result = await store.check(origin: origin, committedURL: page, eager: false)
        XCTAssertEqual(result, .ready)
        XCTAssertFalse(permissions.isAutoApprovePublish(origin: origin.key))
    }

    func testUserRevokeDropsTheRecord() async throws {
        discoveries = [manifest([.publish: "x"])]
        let (token, _) = try await consent()
        try store.decide(token: token, outcome: .allow)
        permissions.revoke(origin: origin.key)
        XCTAssertNil(store.record(for: origin.key))
    }

    func testRecordsSurviveARestart() async throws {
        discoveries = [manifest([.publish: "x"])]
        let (token, _) = try await consent()
        try store.decide(token: token, outcome: .allow)
        let before = store.record(for: origin.key)
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.record(for: origin.key), before)
        XCTAssertEqual(reloaded.origins, [origin.key])
    }
}
