import SwiftData
import XCTest
@testable import Freedom

@MainActor
final class RecordingBridgeReplies: SwarmBridgeReplies {
    private(set) var results: [(id: Int, value: Any)] = []
    private(set) var errors: [(id: Int, dict: [String: Any])] = []
    private(set) var events: [(name: String, data: Any)] = []

    func reply(id: Int, result: Any) { results.append((id, result)) }
    func reply(id: Int, errorObject: [String: Any]) { errors.append((id, errorObject)) }
    func emit(event: String, data: Any) { events.append((event, data)) }
}

@MainActor
final class StubBridgeHost: SwarmBridgeHost {
    var displayURL: URL?
    var pendingSwarmApproval: ApprovalRequest? {
        didSet {
            if let request = pendingSwarmApproval {
                onParked?(request)
            }
        }
    }
    var onParked: ((ApprovalRequest) -> Void)?
}

/// Mutable state the SwarmServices / SwarmRouter closures read live.
/// Lives on a separate reference type so the closures can capture this
/// without reaching back through `self` during fixture init (which trips
/// Swift's definite-init analysis).
@MainActor
final class SwarmBridgeStubs {
    var stamps: [PostageBatch] = []
    var nodeReason: String?
    var routerNodeReason: String?

    var createFeedManifest: SwarmFeedService.CreateManifest?
    var readFeedFromService: SwarmFeedService.ReadFeed?
    var uploadSOC: SwarmFeedService.UploadSOC?
    var uploadBytes: SwarmFeedService.UploadBytes?
    var getChunk: SwarmFeedService.GetChunk?
    var publishUpload: SwarmPublishService.Upload?
    var routerReadFeed: ((String, String, UInt64?) async throws -> SwarmRouter.FeedRead)?

    var pendingDecisions: [ApprovalRequest.Decision] = []
}

/// Drives `SwarmBridge.dispatch(...)` end-to-end without WebKit. Real
/// stores (`SwarmPermissionStore`, `SwarmFeedStore`, `TagOwnership`,
/// `SwarmFeedWriteLock`); closure-stubbed `SwarmFeedService` /
/// `SwarmPublishService`; deterministic `Vault` from a fixed test
/// mnemonic.
///
/// Approval flow: tests queue decisions via `setNextDecision(_:)`; the
/// fixture's `onParked` callback resolves the `ApprovalRequest` on a
/// `Task` hop so the bridge has time to suspend on the continuation.
@MainActor
final class SwarmBridgeTestFixture {
    let container: ModelContainer
    let permissionStore: SwarmPermissionStore
    let feedStore: SwarmFeedStore
    let tagOwnership: TagOwnership
    let feedWriteLock: SwarmFeedWriteLock
    let vault: Vault
    private let vaultService: String

    let host: StubBridgeHost
    let recorder: RecordingBridgeReplies
    let stubs: SwarmBridgeStubs
    let bridge: SwarmBridge

    init() async throws {
        let vaultService = "com.freedom.swarm.bridge.test.\(UUID().uuidString)"
        self.vaultService = vaultService
        let crypto = VaultCrypto(service: vaultService, preferred: .deviceBound)
        let vault = Vault(crypto: crypto)
        try await vault.create(mnemonic: try Mnemonic(phrase: hardhatMnemonic))
        self.vault = vault

        let container = try inMemoryContainer(
            for: SwarmPermission.self,
            SwarmFeedRecord.self,
            SwarmFeedIdentity.self,
            DappPermission.self
        )
        self.container = container
        let permissionStore = SwarmPermissionStore(context: container.mainContext)
        let feedStore = SwarmFeedStore(context: container.mainContext)
        self.permissionStore = permissionStore
        self.feedStore = feedStore
        self.tagOwnership = TagOwnership()
        self.feedWriteLock = SwarmFeedWriteLock()

        let host = StubBridgeHost()
        let recorder = RecordingBridgeReplies()
        let stubs = SwarmBridgeStubs()
        self.host = host
        self.recorder = recorder
        self.stubs = stubs

        let services = SwarmServices(
            permissionStore: permissionStore,
            feedStore: feedStore,
            bee: BeeAPIClient(),
            publishService: SwarmPublishService(upload: { [stubs] path, body, ct, h, q in
                guard let stub = stubs.publishUpload else {
                    XCTFail("publishUpload unexpectedly called")
                    return (Data(), [:])
                }
                return try await stub(path, body, ct, h, q)
            }),
            feedService: SwarmFeedService(
                createFeedManifest: { [stubs] o, t, b in
                    guard let stub = stubs.createFeedManifest else {
                        XCTFail("createFeedManifest unexpectedly called")
                        return ""
                    }
                    return try await stub(o, t, b)
                },
                readFeed: { [stubs] o, t, i in
                    guard let stub = stubs.readFeedFromService else {
                        XCTFail("readFeed unexpectedly called")
                        return BeeAPIClient.FeedReadResult(
                            payload: Data(), index: 0, nextIndex: nil
                        )
                    }
                    return try await stub(o, t, i)
                },
                uploadSOC: { [stubs] o, id, s, body, b in
                    guard let stub = stubs.uploadSOC else {
                        XCTFail("uploadSOC unexpectedly called")
                        return (reference: "", tagUid: nil)
                    }
                    return try await stub(o, id, s, body, b)
                },
                uploadBytes: { [stubs] payload, batch in
                    guard let stub = stubs.uploadBytes else {
                        XCTFail("uploadBytes unexpectedly called")
                        return ""
                    }
                    return try await stub(payload, batch)
                },
                getChunk: { [stubs] ref in
                    guard let stub = stubs.getChunk else {
                        XCTFail("getChunk unexpectedly called")
                        return Data()
                    }
                    return try await stub(ref)
                }
            ),
            vault: vault,
            tagOwnership: tagOwnership,
            feedWriteLock: feedWriteLock,
            nodeFailureReason: { [stubs] in stubs.nodeReason },
            currentStamps: { [stubs] in stubs.stamps }
        )

        let router = SwarmRouter(
            isConnected: { [permissionStore] in permissionStore.isConnected($0) },
            listFeedsForOrigin: { [feedStore] in
                feedStore.all(forOrigin: $0).map(\.asListFeedsRow)
            },
            nodeFailureReason: { [stubs] in stubs.routerNodeReason },
            feedOwner: { [feedStore] origin, name in
                feedStore.lookup(origin: origin, name: name)?.owner
            },
            readFeed: { [stubs] o, t, i in
                guard let stub = stubs.routerReadFeed else {
                    throw SwarmRouter.FeedReadError.notFound
                }
                return try await stub(o, t, i)
            }
        )

        self.bridge = SwarmBridge(
            host: host, router: router, services: services, replies: recorder
        )

        // Task-hop the resolve so the bridge can suspend on the
        // continuation before we resume it — `parkAndAwait` is mid-
        // `withCheckedContinuation` when `pendingSwarmApproval` is set.
        host.onParked = { [stubs] request in
            let decision: ApprovalRequest.Decision
            if stubs.pendingDecisions.isEmpty {
                XCTFail("approval parked but no decision queued for \(request.kind)")
                decision = .denied
            } else {
                decision = stubs.pendingDecisions.removeFirst()
            }
            Task { @MainActor in request.decide(decision) }
        }
    }

    /// Drains the test's Keychain namespace. Tests must call from
    /// `tearDown()` — `VaultCrypto.wipe()` is `@MainActor`, so deinit
    /// can't reach it.
    func tearDownAsync() async throws {
        try VaultCrypto(service: vaultService).wipe()
    }

    /// Decisions resolve in FIFO order — one per park. Tests queue
    /// before calling a handler that would park.
    func setNextDecision(_ decision: ApprovalRequest.Decision) {
        stubs.pendingDecisions.append(decision)
    }

    func dispatch(
        method: String,
        params: [String: Any] = [:],
        origin: OriginIdentity?,
        id: Int = 1
    ) async {
        await bridge.dispatch(id: id, method: method, params: params, origin: origin)
    }
}
