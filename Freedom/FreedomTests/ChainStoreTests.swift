import SwiftData
import XCTest
@testable import Freedom

/// Seeding behavior + CRUD for `ChainStore`. Migration of the legacy
/// `ensPublicRpcProviders` setting is covered separately in
/// `ChainStoreMigrationTests`.
///
/// Container + settings are held as properties so the SwiftData backing
/// outlives every fetch inside a test body — mirrors the lifecycle
/// pattern in `AutoApproveStoreTests`.
@MainActor
final class ChainStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var settings: SettingsStore!
    private var store: ChainStore!

    override func setUp() async throws {
        container = try inMemoryContainer(for: ChainRecord.self)
        settings = SettingsStore(
            defaults: UserDefaults(suiteName: "ChainStoreTests-\(UUID().uuidString)")!
        )
        store = ChainStore(context: container.mainContext, settings: settings)
    }

    // MARK: - Seeding

    func testSeedsMainnetAndGnosisOnFirstLaunch() {
        let chains = store.allChains()
        XCTAssertEqual(chains.map(\.id), [Chain.gnosisID, Chain.mainnetID])
    }

    func testMainnetSeedsWithDefaultProviders() {
        XCTAssertEqual(
            store.rpcURLs(forChainID: Chain.mainnetID),
            SettingsStore.defaultPublicRpcProviders
        )
    }

    func testGnosisSeedsWithChainRegistryURLs() {
        XCTAssertEqual(
            store.rpcURLs(forChainID: Chain.gnosisID),
            ChainRegistry.gnosisURLs.map(\.absoluteString)
        )
    }

    func testSeededChainsCarryNativeMetadata() throws {
        let mainnet = try XCTUnwrap(store.chain(id: Chain.mainnetID))
        XCTAssertEqual(mainnet.nativeName, "Ether")
        XCTAssertEqual(mainnet.nativeSymbol, "ETH")
        XCTAssertEqual(mainnet.nativeDecimals, 18)
        let gnosis = try XCTUnwrap(store.chain(id: Chain.gnosisID))
        XCTAssertEqual(gnosis.nativeName, "xDAI")
        XCTAssertEqual(gnosis.nativeDecimals, 18)
    }

    func testReseedingExistingStoreIsNoOp() {
        store.updateRPCURLs(forChainID: Chain.mainnetID, ["https://custom.example/eth"])
        // A second `ChainStore` against the same context must not reseed.
        let store2 = ChainStore(context: container.mainContext, settings: settings)
        XCTAssertEqual(
            store2.rpcURLs(forChainID: Chain.mainnetID),
            ["https://custom.example/eth"]
        )
    }

    // MARK: - CRUD

    func testUpdateRPCURLs() {
        store.updateRPCURLs(forChainID: Chain.gnosisID, ["https://rpc.example/gnosis"])
        XCTAssertEqual(
            store.rpcURLs(forChainID: Chain.gnosisID),
            ["https://rpc.example/gnosis"]
        )
    }

    func testUpdateRPCURLsOnUnknownChainIsNoOp() {
        store.updateRPCURLs(forChainID: 9999, ["https://rpc.example"])
        XCTAssertNil(store.chain(id: 9999))
    }

    func testAddCustomChain() throws {
        try store.addChain(
            id: 137,
            displayName: "Polygon",
            nativeName: "Polygon",
            nativeSymbol: "POL",
            nativeDecimals: 18,
            explorerBase: "https://polygonscan.com",
            pollIntervalSeconds: 2,
            rpcURLs: ["https://polygon-rpc.com"]
        )
        let chain = try XCTUnwrap(store.chain(id: 137))
        XCTAssertEqual(chain.nativeSymbol, "POL")
        XCTAssertEqual(store.rpcURLs(forChainID: 137), ["https://polygon-rpc.com"])
    }

    func testAddCustomChainRejectsDuplicateID() {
        XCTAssertThrowsError(try store.addChain(
            id: Chain.mainnetID,
            displayName: "Bad",
            nativeName: "Bad",
            nativeSymbol: "BAD",
            nativeDecimals: 18,
            explorerBase: "https://example.com",
            pollIntervalSeconds: 1,
            rpcURLs: ["https://rpc.example"]
        )) { error in
            guard case ChainStore.AddChainError.duplicateID(let id) = error else {
                return XCTFail("expected duplicateID, got \(error)")
            }
            XCTAssertEqual(id, Chain.mainnetID)
        }
    }

    func testDeleteCustomChain() throws {
        try store.addChain(
            id: 137,
            displayName: "Polygon",
            nativeName: "Polygon",
            nativeSymbol: "POL",
            nativeDecimals: 18,
            explorerBase: "https://polygonscan.com",
            pollIntervalSeconds: 2,
            rpcURLs: ["https://polygon-rpc.com"]
        )
        store.deleteChain(id: 137)
        XCTAssertNil(store.chain(id: 137))
    }

    func testDeleteBuiltInChainIsNoOp() {
        store.deleteChain(id: Chain.mainnetID)
        XCTAssertNotNil(store.chain(id: Chain.mainnetID))
        store.deleteChain(id: Chain.gnosisID)
        XCTAssertNotNil(store.chain(id: Chain.gnosisID))
    }
}
