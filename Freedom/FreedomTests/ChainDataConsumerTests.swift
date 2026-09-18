import XCTest
@testable import Freedom

/// Broadcast and fee quotes through the router (desktop
/// `broadcastRawTransaction` / `getFeeQuote` parity): the policy's
/// broadcast order, a terminal uncertain Myotis outcome, node rejections
/// that keep their code, and fee components that always come from one
/// source — on direct, one URL.
@MainActor
final class ChainDataConsumerTests: XCTestCase {
    private var bundle: ChainStackBundle!

    final class Transport: @unchecked Sendable {
        private let lock = NSLock()
        /// host → method → answer
        var answers: [String: [String: Result<Data, Error>]] = [:]
        private(set) var hits: [(host: String, method: String)] = []
        var closure: ChainDataRouter.Transport {
            { [self] url, body, _ in
                let host = url.host ?? ""
                let method = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["method"] as? String ?? ""
                lock.withLock { hits.append((host, method)) }
                guard let answer = lock.withLock({ answers[host]?[method] }) else { throw URLError(.cannotConnectToHost) }
                return try answer.get()
            }
        }
        func hits(for method: String) -> [String] { lock.withLock { hits.filter { $0.method == method }.map(\.host) } }
    }

    override func setUp() async throws {
        try await super.setUp()
        bundle = try ChainStackBundle(orderer: { $0 })
        bundle.chainStore.updateRPCURLs(forChainID: 1, ["https://a.example", "https://b.example"])
    }

    private func router(_ transport: Transport, sources: [ChainDataSource] = [], policy: ChainAccessPolicy? = nil) -> ChainDataRouter {
        bundle.registry.verifiedSources = sources
        if let policy { bundle.registry.policyOverrides[1] = policy }
        return ChainDataRouter(registry: bundle.registry, transport: transport.closure)
    }

    private let raw = "0x02f8aa"

    // MARK: - Broadcast

    func testMyotisBroadcastsBeforeDirect() async throws {
        let myotis = ChainDataRouterTests.FakeSource(.myotis)
        myotis.served["eth_sendRawTransaction"] = "0xfeed"
        let transport = Transport()
        let receipt = try await router(transport, sources: [myotis]).broadcast(chainID: 1, rawTransaction: raw)
        XCTAssertEqual(receipt.hash, "0xfeed")
        XCTAssertEqual(receipt.source, .myotis)
        XCTAssertTrue(transport.hits.isEmpty)
        XCTAssertEqual(myotis.calls.first?.params.first as? String, raw)
    }

    func testUncertainMyotisOutcomeIsTerminal() async throws {
        let myotis = ChainDataRouterTests.FakeSource(.myotis)
        myotis.served["eth_sendRawTransaction"] = "0xfeed"
        myotis.failure = ChainSourceUnavailable(reason: "no peers accepted the transaction")
        let transport = Transport()
        transport.answers["a.example"] = ["eth_sendRawTransaction": .success(try rpcResult("0xother"))]
        do {
            _ = try await router(transport, sources: [myotis]).broadcast(chainID: 1, rawTransaction: raw)
            XCTFail("expected broadcastUncertain")
        } catch WalletRPC.Error.broadcastUncertain(let message) {
            XCTAssertTrue(message.contains("no peers"))
        }
        XCTAssertTrue(transport.hits.isEmpty, "never re-broadcast after an uncertain devp2p outcome")
    }

    func testDirectBroadcastWhenMyotisIsNotReady() async throws {
        let myotis = ChainDataRouterTests.FakeSource(.myotis)
        myotis.served["eth_sendRawTransaction"] = "0xfeed"
        myotis.available = false
        let transport = Transport()
        transport.answers["a.example"] = ["eth_sendRawTransaction": .success(try rpcResult("0xdirect"))]
        let receipt = try await router(transport, sources: [myotis]).broadcast(chainID: 1, rawTransaction: raw)
        XCTAssertEqual(receipt.hash, "0xdirect")
        XCTAssertEqual(receipt.source, .direct)
        XCTAssertTrue(myotis.calls.isEmpty)
    }

    func testNodeRejectionKeepsItsCode() async throws {
        let transport = Transport()
        transport.answers["a.example"] = ["eth_sendRawTransaction": .success(try rpcError(code: -32000, message: "nonce too low"))]
        transport.answers["b.example"] = ["eth_sendRawTransaction": .success(try rpcError(code: -32000, message: "already known"))]
        do {
            _ = try await router(transport).broadcast(chainID: 1, rawTransaction: raw)
            XCTFail("expected failure")
        } catch WalletRPC.Error.allProvidersFailed(let errors) {
            XCTAssertEqual(errors.count, 2)
            guard case WalletRPC.Error.rpc(let code, let message)? = errors.first as? WalletRPC.Error else {
                return XCTFail("expected the node's JSON-RPC error")
            }
            XCTAssertEqual(code, -32000)
            XCTAssertEqual(message, "nonce too low")
        }
        XCTAssertEqual(transport.hits(for: "eth_sendRawTransaction"), ["a.example", "b.example"])
    }

    func testBroadcastOrderIsThePolicys() async throws {
        let myotis = ChainDataRouterTests.FakeSource(.myotis)
        myotis.served["eth_sendRawTransaction"] = "0xfeed"
        let transport = Transport()
        transport.answers["a.example"] = ["eth_sendRawTransaction": .success(try rpcResult("0xdirect"))]
        let policy = ChainAccessPolicy(readOrder: [.direct], broadcastOrder: [.direct])
        let receipt = try await router(transport, sources: [myotis], policy: policy).broadcast(chainID: 1, rawTransaction: raw)
        XCTAssertEqual(receipt.source, .direct)
        XCTAssertTrue(myotis.calls.isEmpty)
    }

    // MARK: - Fee quote

    private func header(_ baseFee: String?) throws -> Data {
        try rpcResult(baseFee.map { ["baseFeePerGas": $0] } ?? [:])
    }

    func testMyotisGivesACompleteQuote() async throws {
        let myotis = ChainDataRouterTests.FakeSource(.myotis)
        myotis.served["eth_gasPrice"] = "0x77359400"
        myotis.served["eth_getBlockByNumber"] = ["baseFeePerGas": "0x3b9aca00"]
        let transport = Transport()
        let quote = try await router(transport, sources: [myotis]).feeQuote(chainID: 1)
        XCTAssertEqual(quote.gasPriceHex, "0x77359400")
        XCTAssertEqual(quote.baseFeePerGasHex, "0x3b9aca00")
        XCTAssertEqual(quote.source, .myotis)
        XCTAssertEqual(quote.trust.level, .verified)
        XCTAssertTrue(transport.hits.isEmpty)
    }

    func testSourceThatCannotGiveBothComponentsFallsThroughWhole() async throws {
        // Myotis quotes a price but not the header: the quote must not
        // mix its price with another source's base fee.
        let myotis = ChainDataRouterTests.FakeSource(.myotis)
        myotis.served["eth_gasPrice"] = "0x1"
        let transport = Transport()
        transport.answers["a.example"] = [
            "eth_gasPrice": .success(try rpcResult("0x77359400")),
            "eth_getBlockByNumber": .success(try header("0x3b9aca00")),
        ]
        let quote = try await router(transport, sources: [myotis]).feeQuote(chainID: 1)
        XCTAssertEqual(quote.source, .direct)
        XCTAssertEqual(quote.gasPriceHex, "0x77359400")
        XCTAssertEqual(quote.baseFeePerGasHex, "0x3b9aca00")
    }

    func testDirectTakesBothComponentsFromTheSameURL() async throws {
        let transport = Transport()
        // a quotes a price but cannot serve its head → skipped whole.
        transport.answers["a.example"] = ["eth_gasPrice": .success(try rpcResult("0x1"))]
        transport.answers["b.example"] = [
            "eth_gasPrice": .success(try rpcResult("0x2")),
            "eth_getBlockByNumber": .success(try header(nil)),
        ]
        let quote = try await router(transport).feeQuote(chainID: 1)
        XCTAssertEqual(quote.gasPriceHex, "0x2")
        XCTAssertNil(quote.baseFeePerGasHex, "pre-London header: no base fee, the quote stands")
        XCTAssertEqual(quote.trust.agreed, ["b.example"])
        XCTAssertEqual(transport.hits(for: "eth_gasPrice"), ["a.example", "b.example"])
    }

    func testQuorumQuoteNeedsAgreementOnBoth() async throws {
        let shipped = Array(SettingsStore.defaultPublicRpcProviders.prefix(3))
        bundle.chainStore.updateRPCURLs(forChainID: 1, shipped)
        let transport = Transport()
        for url in shipped {
            transport.answers[URL(string: url)!.host!] = [
                "eth_gasPrice": .success(try rpcResult("0x5")),
                "eth_getBlockByNumber": .success(try header("0x4")),
            ]
        }
        let policy = ChainAccessPolicy(readOrder: [.quorum, .direct], broadcastOrder: [.direct])
        let quote = try await router(transport, policy: policy).feeQuote(chainID: 1)
        XCTAssertEqual(quote.source, .quorum)
        XCTAssertEqual(quote.trust.level, .verified)
        XCTAssertEqual(quote.baseFeePerGasHex, "0x4")
    }

    func testGasOracleUsesTheRouterQuote() async throws {
        let myotis = ChainDataRouterTests.FakeSource(.myotis)
        myotis.served["eth_gasPrice"] = "0x3b9aca00"                       // 1 gwei
        myotis.served["eth_getBlockByNumber"] = ["baseFeePerGas": "0x77359400"]  // 2 gwei
        let router = router(Transport(), sources: [myotis])
        let oracle = GasOracle(rpc: WalletRPC(router: router))
        let price = try await oracle.suggestedGasPrice(on: .mainnet)
        // Floored to 2 gwei × 1.25 + 1 gwei tip.
        XCTAssertEqual(price, 3_500_000_000)
    }
}
