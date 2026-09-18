import SwiftData
import XCTest
@testable import Freedom

/// Persisted per-chain routing policy and the seed snapshot on
/// `ChainRecord`: defaults, round trip, sanitizing, the mainnet policy
/// sharing the ENS quorum keys, user-added vs shipped endpoints, reset,
/// and the seed refresh for records from older builds.
@MainActor
final class ChainPolicyStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var settings: SettingsStore!
    private var store: ChainStore!

    override func setUp() async throws {
        container = try inMemoryContainer(for: ChainRecord.self)
        settings = SettingsStore(defaults: UserDefaults(suiteName: "ChainPolicy-\(UUID().uuidString)")!)
        store = ChainStore(context: container.mainContext, settings: settings)
    }

    private func addBase() throws {
        try store.addChain(
            id: 8453, displayName: "Base", nativeName: "Ether", nativeSymbol: "ETH", nativeDecimals: 18,
            explorerBase: "https://basescan.org", pollIntervalSeconds: 2,
            rpcURLs: ["https://mainnet.base.org", "https://base-rpc.publicnode.com"]
        )
    }

    // MARK: - Policy

    func testFreshRecordsCarryDesktopDefaults() async throws {
        XCTAssertEqual(store.policy(forChainID: 1).readOrder, [.myotis, .colibri, .quorum, .direct])
        XCTAssertEqual(store.policy(forChainID: 100).broadcastOrder, [.myotis, .direct])
        try addBase()
        XCTAssertEqual(store.policy(forChainID: 8453).readOrder, [.quorum, .direct])
        XCTAssertEqual(store.policy(forChainID: 8453).broadcastOrder, [.direct])
        XCTAssertEqual(store.policy(forChainID: 8453).quorumK, 3)
    }

    func testPolicyRoundTripsAndBumpsVersion() async throws {
        try addBase()
        let before = store.version
        var policy = store.policy(forChainID: 8453)
        policy.readOrder = [.direct, .quorum]
        policy.quorumK = 4
        policy.quorumM = 3
        policy.quorumTimeoutMs = 900
        policy.proverURL = "https://prover.example"
        policy.zkProof = false
        store.updatePolicy(forChainID: 8453, policy)
        XCTAssertGreaterThan(store.version, before)
        let stored = store.policy(forChainID: 8453)
        XCTAssertEqual(stored.readOrder, [.direct, .quorum])
        XCTAssertEqual(stored.quorumK, 4)
        XCTAssertEqual(stored.quorumM, 3)
        XCTAssertEqual(stored.quorumTimeoutMs, 900)
        XCTAssertEqual(stored.proverURL, "https://prover.example")
        XCTAssertFalse(stored.zkProof)
        // A second store over the same context reads the same record.
        let reopened = ChainStore(context: container.mainContext, settings: settings)
        XCTAssertEqual(reopened.policy(forChainID: 8453), stored)
    }

    func testImpossibleQuorumNumbersAreClampedOnWrite() async throws {
        try addBase()
        var policy = store.policy(forChainID: 8453)
        policy.quorumK = 2
        policy.quorumM = 5
        policy.quorumTimeoutMs = 10
        store.updatePolicy(forChainID: 8453, policy)
        let stored = store.policy(forChainID: 8453)
        XCTAssertEqual(stored.quorumM, 2)
        XCTAssertEqual(stored.quorumTimeoutMs, ChainAccessPolicy.minimumTimeoutMs)
    }

    func testMainnetPolicySharesTheENSQuorumKeys() async throws {
        settings.ensQuorumK = 5
        settings.ensQuorumM = 4
        settings.ensColibriProverUrl = "https://my-prover.example"
        settings.ensColibriZkProof = false
        let policy = store.policy(forChainID: 1)
        XCTAssertEqual(policy.quorumK, 5)
        XCTAssertEqual(policy.quorumM, 4)
        XCTAssertEqual(policy.proverURL, "https://my-prover.example")
        XCTAssertFalse(policy.zkProof)

        var edited = policy
        edited.quorumK = 3
        edited.quorumM = 2
        edited.proverURL = ""
        edited.zkProof = true
        store.updatePolicy(forChainID: 1, edited)
        XCTAssertEqual(settings.ensQuorumK, 3, "the Chains page and the ENS page edit one value")
        XCTAssertEqual(settings.ensQuorumM, 2)
        XCTAssertEqual(settings.ensColibriProverUrl, "")
        XCTAssertTrue(settings.ensColibriZkProof)
    }

    func testRegistryReadsTheStoredPolicy() async throws {
        let registry = ChainRegistry(chainStore: store, mainnetPool: mainnetPool(settings: settings))
        var policy = store.policy(forChainID: 100)
        policy.readOrder = [.direct]
        store.updatePolicy(forChainID: 100, policy)
        XCTAssertEqual(registry.policy(forChainID: 100).readOrder, [.direct])
        // Unsupported tiers stored by an older build are dropped on read.
        try addBase()
        var base = store.policy(forChainID: 8453)
        base.readOrder = [.myotis, .colibri, .direct]
        store.updatePolicy(forChainID: 8453, base)
        XCTAssertEqual(registry.policy(forChainID: 8453).readOrder, [.direct])
    }

    // MARK: - Endpoints

    func testShippedAndUserAddedEndpoints() async throws {
        XCTAssertEqual(store.defaultRPCURLs(forChainID: 1), SettingsStore.defaultPublicRpcProviders)
        XCTAssertTrue(store.userAddedRPCURLs(forChainID: 1).isEmpty)
        store.updateRPCURLs(forChainID: 1, ["https://my.node"] + SettingsStore.defaultPublicRpcProviders)
        XCTAssertEqual(store.userAddedRPCURLs(forChainID: 1), ["https://my.node"])
        XCTAssertTrue(store.isUserAddedRPCURL("https://MY.node", chainID: 1), "case-insensitive")
        XCTAssertFalse(store.isUserAddedRPCURL(SettingsStore.defaultPublicRpcProviders[0], chainID: 1))
        store.resetRPCURLs(forChainID: 1)
        XCTAssertEqual(store.rpcURLs(forChainID: 1), SettingsStore.defaultPublicRpcProviders)
    }

    func testCustomChainSnapshotIsItsInitialList() async throws {
        try addBase()
        XCTAssertEqual(store.defaultRPCURLs(forChainID: 8453), ["https://mainnet.base.org", "https://base-rpc.publicnode.com"])
        store.updateRPCURLs(forChainID: 8453, ["https://mine.example", "https://mainnet.base.org"])
        XCTAssertEqual(store.userAddedRPCURLs(forChainID: 8453), ["https://mine.example"])
        store.resetRPCURLs(forChainID: 8453)
        XCTAssertEqual(store.rpcURLs(forChainID: 8453).count, 2)
    }

    // MARK: - Seed refresh

    /// A record seeded by an older build carries the old list and no
    /// snapshot: dead defaults go, the user's own endpoint stays first.
    func testOlderBuildRecordIsRefreshedKeepingUserEndpoints() async throws {
        let legacy = Array(SettingsStore.legacyPublicRpcProviders).sorted()
        let record = try XCTUnwrap(container.mainContext.fetchRecord(id: 1))
        record.rpcURLs = ["https://my.node"] + legacy
        record.defaultRPCURLs = []
        try container.mainContext.save()

        let refreshed = ChainStore(context: container.mainContext, settings: settings)
        XCTAssertEqual(refreshed.rpcURLs(forChainID: 1), ["https://my.node"] + SettingsStore.defaultPublicRpcProviders)
        XCTAssertEqual(refreshed.defaultRPCURLs(forChainID: 1), SettingsStore.defaultPublicRpcProviders)
        XCTAssertEqual(refreshed.userAddedRPCURLs(forChainID: 1), ["https://my.node"])
    }

    func testPrivateOnlyRecordIsLeftAlone() async throws {
        let record = try XCTUnwrap(container.mainContext.fetchRecord(id: 1))
        record.rpcURLs = ["https://my.node"]
        record.defaultRPCURLs = []
        try container.mainContext.save()
        let refreshed = ChainStore(context: container.mainContext, settings: settings)
        XCTAssertEqual(refreshed.rpcURLs(forChainID: 1), ["https://my.node"], "a deliberately private list gets no public endpoints injected")
        XCTAssertEqual(refreshed.defaultRPCURLs(forChainID: 1), SettingsStore.defaultPublicRpcProviders)
    }

    func testRefreshIsIdempotent() async throws {
        let again = ChainStore(context: container.mainContext, settings: settings)
        XCTAssertEqual(again.rpcURLs(forChainID: 100), ChainRegistry.gnosisURLs.map(\.absoluteString))
        XCTAssertEqual(again.version, 0, "no seed and no refresh write on an up-to-date store")
    }
}

private extension ModelContext {
    func fetchRecord(id: Int) throws -> ChainRecord? {
        try fetch(FetchDescriptor<ChainRecord>()).first { $0.id == id }
    }
}
