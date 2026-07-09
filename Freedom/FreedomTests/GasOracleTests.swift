import BigInt
import XCTest
@testable import Freedom

/// Covers the interim gas-pricing hardening (freedom-browser-ios#1):
/// base-fee sanity floor over a lowball `eth_gasPrice`, and hard errors
/// instead of the old silent `BigUInt(0)` fallback.
@MainActor
final class GasOracleTests: XCTestCase {
    private var chainStack: ChainStackBundle!

    override func setUp() async throws {
        try await super.setUp()
        chainStack = try ChainStackBundle()
    }

    /// Method-keyed stub. Unlike `TransactionServiceTests.StubRPC` this
    /// never dequeues — the oracle's two RPCs race, and a test asserting
    /// on price math shouldn't care about call multiplicity.
    private func makeOracle(responses: [String: Data]) -> GasOracle {
        let registry = chainStack.registry
        let transport: WalletRPC.Transport = { _, body in
            let parsed = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let method = parsed?["method"] as? String ?? ""
            guard let response = responses[method] else { throw URLError(.unknown) }
            return response
        }
        return GasOracle(rpc: WalletRPC(registry: registry, transport: transport))
    }

    private let gwei = BigUInt(1_000_000_000)

    // MARK: - Base-fee floor

    func testLowballQuoteIsFlooredToBaseFeeWithHeadroom() async throws {
        // Field incident shape: provider quotes 1 gwei while the base fee
        // is 2 gwei — the raw quote can never mine.
        let oracle = makeOracle(responses: [
            "eth_gasPrice": try rpcResult("0x3b9aca00"),  // 1 gwei
            "eth_getBlockByNumber": try rpcResult(["baseFeePerGas": "0x77359400"]),  // 2 gwei
        ])
        let price = try await oracle.suggestedGasPrice(on: .gnosis)
        // 2 gwei × 1.25 + 1 gwei tip
        XCTAssertEqual(price, gwei * 25 / 10 + gwei)
    }

    func testHealthyQuoteAboveFloorPassesThrough() async throws {
        let oracle = makeOracle(responses: [
            "eth_gasPrice": try rpcResult("0x12a05f200"),  // 5 gwei
            "eth_getBlockByNumber": try rpcResult(["baseFeePerGas": "0x3b9aca00"]),  // 1 gwei
        ])
        let price = try await oracle.suggestedGasPrice(on: .gnosis)
        XCTAssertEqual(price, gwei * 5)
    }

    func testZeroQuoteWithBaseFeeIsFloored() async throws {
        let oracle = makeOracle(responses: [
            "eth_gasPrice": try rpcResult("0x0"),
            "eth_getBlockByNumber": try rpcResult(["baseFeePerGas": "0x3b9aca00"]),  // 1 gwei
        ])
        let price = try await oracle.suggestedGasPrice(on: .gnosis)
        XCTAssertEqual(price, gwei * 125 / 100 + gwei)
    }

    // MARK: - Pre-London (no baseFeePerGas in the header)

    func testMissingBaseFeePassesQuoteThrough() async throws {
        let oracle = makeOracle(responses: [
            "eth_gasPrice": try rpcResult("0x77359400"),  // 2 gwei
            "eth_getBlockByNumber": try rpcResult(["number": "0x1"]),
        ])
        let price = try await oracle.suggestedGasPrice(on: .gnosis)
        XCTAssertEqual(price, gwei * 2)
    }

    // MARK: - Hard errors, never a zero price

    func testGarbageQuoteThrowsInsteadOfZeroFallback() async throws {
        let oracle = makeOracle(responses: [
            "eth_gasPrice": try rpcResult("not-hex"),
            "eth_getBlockByNumber": try rpcResult(["baseFeePerGas": "0x3b9aca00"]),
        ])
        do {
            _ = try await oracle.suggestedGasPrice(on: .gnosis)
            XCTFail("expected unparseableQuote")
        } catch GasOracle.Error.unparseableQuote(let hex) {
            XCTAssertEqual(hex, "not-hex")
        }
    }

    func testZeroQuoteWithoutBaseFeeThrows() async throws {
        let oracle = makeOracle(responses: [
            "eth_gasPrice": try rpcResult("0x0"),
            "eth_getBlockByNumber": try rpcResult(["number": "0x1"]),
        ])
        do {
            _ = try await oracle.suggestedGasPrice(on: .gnosis)
            XCTFail("expected zeroQuote")
        } catch GasOracle.Error.zeroQuote {
            // expected
        }
    }
}
