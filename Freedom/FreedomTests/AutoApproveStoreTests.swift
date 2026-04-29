import SwiftData
import web3
import XCTest
@testable import Freedom

@MainActor
final class AutoApproveStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var store: AutoApproveStore!

    private let origin = "app.uniswap.org"
    private let usdc: EthereumAddress = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
    private let dai: EthereumAddress = "0x6b175474e89094c44da98b954eedeac495271d0f"
    private let transfer = "0xa9059cbb"
    private let approve = "0x095ea7b3"

    override func setUp() async throws {
        container = try inMemoryContainer(for: AutoApproveRule.self)
        store = AutoApproveStore(context: container.mainContext)
    }

    private func offer(
        origin: String? = nil,
        contract: EthereumAddress? = nil,
        selector: String? = nil,
        chainID: Int = 1
    ) -> AutoApproveOffer {
        AutoApproveOffer(
            origin: origin ?? self.origin,
            contract: contract ?? usdc,
            selector: selector ?? transfer,
            selectorLabel: nil,
            chainID: chainID
        )
    }

    func testGrantThenMatch() {
        let o = offer()
        XCTAssertFalse(store.matches(o))
        store.grant(o)
        XCTAssertTrue(store.matches(o))
    }

    /// Stored normalized; lookups via either casing succeed because
    /// `EthereumAddress` round-trips through `.asString().lowercased()`
    /// inside `AutoApproveRule.makeKey`.
    func testGrantNormalizesSelectorCase() {
        store.grant(offer(selector: transfer.uppercased()))
        XCTAssertTrue(store.matches(offer(selector: transfer)))
        XCTAssertTrue(store.matches(offer(selector: transfer.uppercased())))
    }

    func testGrantIsIdempotent() {
        let o = offer()
        store.grant(o)
        store.grant(o)
        let descriptor = FetchDescriptor<AutoApproveRule>()
        let count = (try? container.mainContext.fetch(descriptor).count) ?? 0
        XCTAssertEqual(count, 1, "grant on an existing key should be a no-op, not a dup insert")
    }

    func testRevokeDropsTheRule() {
        let o = offer()
        store.grant(o)
        let descriptor = FetchDescriptor<AutoApproveRule>()
        let rule = try! container.mainContext.fetch(descriptor).first!
        store.revoke(rule)
        XCTAssertFalse(store.matches(o))
    }

    /// Cross-contract isolation: a rule for USDC.transfer doesn't auto-fire
    /// on DAI.transfer even though selectors match.
    func testCrossContractIsNotMatched() {
        store.grant(offer(contract: usdc))
        XCTAssertFalse(store.matches(offer(contract: dai)))
    }

    func testCrossChainIsNotMatched() {
        store.grant(offer(chainID: 1))
        XCTAssertFalse(store.matches(offer(chainID: 100)))
    }

    func testCrossSelectorIsNotMatched() {
        store.grant(offer(selector: transfer))
        XCTAssertFalse(store.matches(offer(selector: approve)))
    }

    /// Cross-origin isolation: a rule on uniswap.org doesn't fire on a
    /// phisher imitating the same call.
    func testCrossOriginIsNotMatched() {
        store.grant(offer(origin: "app.uniswap.org"))
        XCTAssertFalse(store.matches(offer(origin: "evil.example.com")))
    }
}
