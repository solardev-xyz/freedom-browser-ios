import SwiftData
import XCTest
@testable import Freedom

/// Per-chain pool routing through `ChainRegistry`. The mainnet pool is
/// injected and its instance identity is preserved (so `ENSResolver`
/// and the registry share quarantine state); other chains' pools are
/// lazily materialized from `ChainStore` and memoized.
@MainActor
final class ChainRegistryTests: XCTestCase {
    private var stack: ChainStackBundle!

    override func setUp() async throws {
        try await super.setUp()
        // Identity orderer keeps URL order deterministic for the
        // routing assertions below.
        stack = try ChainStackBundle(orderer: { $0 })
    }

    // MARK: - Routing

    func testRPCURLsForMainnetReturnsInjectedPoolList() {
        XCTAssertEqual(
            stack.registry.rpcURLs(for: .mainnet),
            stack.mainnetPool.availableProviders()
        )
    }

    func testRPCURLsForGnosisReturnsChainStoreList() {
        XCTAssertEqual(
            stack.registry.rpcURLs(for: .gnosis),
            ChainRegistry.gnosisURLs
        )
    }

    // MARK: - Pool identity

    func testMainnetPoolIdentityIsPreserved() {
        // Mainnet `markSuccess`/`markFailure` must hit the injected pool so
        // the resolver (which holds the same reference) sees quarantine.
        let mainnetURL = stack.mainnetPool.availableProviders().first!
        stack.registry.markFailure(url: mainnetURL, on: .mainnet)
        XCTAssertFalse(stack.mainnetPool.availableProviders().contains(mainnetURL),
                       "registry mainnet failure must quarantine the injected pool")
    }

    func testGnosisFailureDoesNotAffectMainnetPool() {
        let mainnetCount = stack.mainnetPool.availableProviders().count
        let gnosisURL = ChainRegistry.gnosisURLs.first!
        stack.registry.markFailure(url: gnosisURL, on: .gnosis)
        XCTAssertEqual(stack.mainnetPool.availableProviders().count, mainnetCount,
                       "gnosis quarantine must not leak into mainnet")
    }

    func testGnosisQuarantineRemovesURLFromGnosisList() {
        let gnosisURL = ChainRegistry.gnosisURLs.first!
        stack.registry.markFailure(url: gnosisURL, on: .gnosis)
        XCTAssertFalse(stack.registry.rpcURLs(for: .gnosis).contains(gnosisURL))
    }

    // MARK: - Invalidation

    func testInvalidateAllPoolsClearsQuarantineAcrossChains() {
        let mainnetURL = stack.mainnetPool.availableProviders().first!
        let gnosisURL = ChainRegistry.gnosisURLs.first!
        stack.registry.markFailure(url: mainnetURL, on: .mainnet)
        stack.registry.markFailure(url: gnosisURL, on: .gnosis)
        XCTAssertFalse(stack.registry.rpcURLs(for: .mainnet).contains(mainnetURL))
        XCTAssertFalse(stack.registry.rpcURLs(for: .gnosis).contains(gnosisURL))

        stack.registry.invalidateAllPools()

        XCTAssertTrue(stack.registry.rpcURLs(for: .mainnet).contains(mainnetURL))
        XCTAssertTrue(stack.registry.rpcURLs(for: .gnosis).contains(gnosisURL))
    }

    // MARK: - Lazy custom-chain pool

    func testCustomChainPoolLazilyMaterializesFromChainStore() throws {
        try stack.chainStore.addChain(
            id: 137,
            displayName: "Polygon",
            nativeName: "Polygon",
            nativeSymbol: "POL",
            nativeDecimals: 18,
            explorerBase: "https://polygonscan.com",
            pollIntervalSeconds: 2,
            rpcURLs: ["https://polygon-rpc.com"]
        )
        let polygon = try XCTUnwrap(stack.chainStore.chain(id: 137))
        XCTAssertEqual(
            stack.registry.rpcURLs(for: polygon).map(\.absoluteString),
            ["https://polygon-rpc.com"]
        )
    }
}
