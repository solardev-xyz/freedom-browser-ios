import XCTest
import MyotisKit
@testable import Freedom

/// The verified-source ladder inside `WalletRPC` (desktop
/// chain-data-router parity): sources answer ahead of the RPC pool,
/// unavailability falls through silently, deterministic answers
/// short-circuit, and params-aware gating keeps unservable shapes off
/// the verified tiers.
@MainActor
final class ChainSourceRouterTests: XCTestCase {
    private var bundle: ChainStackBundle!

    /// Configurable fake source. `served` maps method → result;
    /// `failure` (when set) is thrown for served methods instead.
    private final class FakeSource: ChainDataSource {
        let sourceName: String
        var available = true
        var served: [String: Any] = [:]
        var failure: Error?
        var calls: [String] = []

        init(name: String = "fake") { sourceName = name }

        func isAvailable(chainID: Int) -> Bool { available }
        func serves(method: String, params: [Any], chainID: Int) -> Bool {
            served.keys.contains(method)
        }
        func result(method: String, params: [Any], chainID: Int) async throws -> Any {
            calls.append(method)
            if let failure { throw failure }
            return served[method]!
        }
    }

    /// Transport stub that records hits; `result` nil → connection error.
    private final class TransportStub: @unchecked Sendable {
        private let lock = NSLock()
        private var hits = 0
        private let payload: Data?

        init(payload: Data?) { self.payload = payload }

        var hitCount: Int {
            lock.lock(); defer { lock.unlock() }
            return hits
        }

        var transport: WalletRPC.Transport {
            { [self] _, _ in
                lock.lock(); hits += 1; lock.unlock()
                guard let payload else { throw URLError(.cannotConnectToHost) }
                return payload
            }
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        bundle = try ChainStackBundle(orderer: { $0 })
    }

    private func rpc(
        sources: [ChainDataSource],
        poolResult: Data? = nil
    ) -> (WalletRPC, TransportStub) {
        bundle.registry.verifiedSources = sources
        let stub = TransportStub(payload: poolResult)
        let rpc = WalletRPC(registry: bundle.registry, transport: stub.transport)
        return (rpc, stub)
    }

    // MARK: - Ladder behavior

    func testVerifiedSourceAnswersBeforePool() async throws {
        let source = FakeSource()
        source.served["eth_getBalance"] = "0x1bc16d674ec80000"
        let (rpc, stub) = rpc(sources: [source], poolResult: try rpcResult("0xdead"))
        let balance = try await rpc.balance(of: "0xabc", on: .mainnet)
        XCTAssertEqual(balance, "0x1bc16d674ec80000")
        XCTAssertEqual(stub.hitCount, 0, "pool must not be consulted when a source serves")
    }

    func testUnavailableSourceFallsThroughToPool() async throws {
        let source = FakeSource()
        source.served["eth_getBalance"] = "0x1"
        source.failure = ChainSourceUnavailable(reason: "no snap peer")
        let (rpc, stub) = rpc(sources: [source], poolResult: try rpcResult("0xfb"))
        let balance = try await rpc.balance(of: "0xabc", on: .mainnet)
        XCTAssertEqual(balance, "0xfb")
        XCTAssertEqual(stub.hitCount, 1)
        XCTAssertEqual(source.calls, ["eth_getBalance"], "source must have been attempted")
    }

    func testNotAvailableSourceIsSkippedWithoutAttempt() async throws {
        let source = FakeSource()
        source.served["eth_getBalance"] = "0x1"
        source.available = false
        let (rpc, _) = rpc(sources: [source], poolResult: try rpcResult("0xfb"))
        let balance = try await rpc.balance(of: "0xabc", on: .mainnet)
        XCTAssertEqual(balance, "0xfb")
        XCTAssertTrue(source.calls.isEmpty)
    }

    func testUnservedMethodBypassesSource() async throws {
        // The wallet's nonce read uses the "pending" tag; a source that
        // only claims balances must never see it.
        let source = FakeSource()
        source.served["eth_getBalance"] = "0x1"
        let (rpc, stub) = rpc(sources: [source], poolResult: try rpcResult("0x7"))
        let nonce = try await rpc.transactionCount(of: "0xabc", on: .mainnet)
        XCTAssertEqual(nonce, "0x7")
        XCTAssertEqual(stub.hitCount, 1)
        XCTAssertTrue(source.calls.isEmpty)
    }

    func testDeterministicAnswerShortCircuits() async throws {
        // A verified revert (code 3) must surface, not fall through to a
        // source that might answer differently.
        let source = FakeSource()
        source.served["eth_call"] = "0x"
        source.failure = WalletRPC.Error.rpc(code: 3, message: "execution reverted 0x08c379a0")
        let (rpc, stub) = rpc(sources: [source], poolResult: try rpcResult("0xshould-not-reach"))
        do {
            _ = try await rpc.callJSON(
                method: "eth_call",
                params: [["to": "0xabc", "data": "0x01"]],
                on: .mainnet
            )
            XCTFail("expected rpc error")
        } catch let WalletRPC.Error.rpc(code, message) {
            XCTAssertEqual(code, 3)
            XCTAssertTrue(message.contains("execution reverted"))
        }
        XCTAssertEqual(stub.hitCount, 0, "deterministic answer must not consult the pool")
    }

    func testSourceOrderIsRespected() async throws {
        let first = FakeSource(name: "first")
        first.served["eth_getBalance"] = "0x1"
        let second = FakeSource(name: "second")
        second.served["eth_getBalance"] = "0x2"
        let (rpc, _) = rpc(sources: [first, second], poolResult: try rpcResult("0xfb"))
        let balance = try await rpc.balance(of: "0xabc", on: .mainnet)
        XCTAssertEqual(balance, "0x1")
        XCTAssertTrue(second.calls.isEmpty)
    }

    func testFirstSourceUnavailableSecondServes() async throws {
        let first = FakeSource(name: "first")
        first.served["eth_getBalance"] = "0x1"
        first.failure = ChainSourceUnavailable(reason: "syncing")
        let second = FakeSource(name: "second")
        second.served["eth_getBalance"] = "0x2"
        let (rpc, stub) = rpc(sources: [first, second], poolResult: try rpcResult("0xfb"))
        let balance = try await rpc.balance(of: "0xabc", on: .mainnet)
        XCTAssertEqual(balance, "0x2")
        XCTAssertEqual(stub.hitCount, 0)
    }

    func testNullResultServesCallOptional() async throws {
        // Verified "not seen" (still pending) from a source must reach
        // callers as nil, exactly like a pool null.
        let source = FakeSource()
        source.served["eth_getTransactionByHash"] = NSNull()
        let (rpc, stub) = rpc(sources: [source], poolResult: nil)
        let info = try await rpc.getTransaction(hash: "0xhash", on: .mainnet)
        XCTAssertNil(info)
        XCTAssertEqual(stub.hitCount, 0)
    }

    func testEmptySourcesPreservePoolBehavior() async throws {
        let (rpc, stub) = rpc(sources: [], poolResult: try rpcResult("0xfb"))
        let balance = try await rpc.balance(of: "0xabc", on: .mainnet)
        XCTAssertEqual(balance, "0xfb")
        XCTAssertEqual(stub.hitCount, 1)
    }

    // MARK: - Call-shape gates (pure)

    func testServableCallAcceptsCleanShape() {
        XCTAssertTrue(ChainCallShape.servableCall([["to": "0xabc", "data": "0x01"]]))
        XCTAssertTrue(ChainCallShape.servableCall([
            ["from": "0xdef", "to": "0xabc", "data": "0x01", "value": "0x1"], "latest",
        ]))
        XCTAssertTrue(ChainCallShape.servableCall([["to": "0xabc", "input": "0x01"]]))
    }

    func testServableCallRejectsUnhonorableShapes() {
        // Non-latest tag.
        XCTAssertFalse(ChainCallShape.servableCall([["to": "0xa"], "pending"]))
        XCTAssertFalse(ChainCallShape.servableCall([["to": "0xa"], "0x10"]))
        // State overrides.
        XCTAssertFalse(ChainCallShape.servableCall([["to": "0xa"], "latest", ["0xb": ["balance": "0x1"]]]))
        // Unsupported call fields would be silently dropped — reject.
        XCTAssertFalse(ChainCallShape.servableCall([["to": "0xa", "gas": "0x5208"]]))
        XCTAssertFalse(ChainCallShape.servableCall([["to": "0xa", "maxFeePerGas": "0x1"]]))
        XCTAssertFalse(ChainCallShape.servableCall([["to": "0xa", "nonce": "0x1"]]))
        // Conflicting calldata aliases.
        XCTAssertFalse(ChainCallShape.servableCall([["to": "0xa", "data": "0x01", "input": "0x02"]]))
        // Contract creation (no `to`) isn't served.
        XCTAssertFalse(ChainCallShape.servableCall([["data": "0x01"]]))
    }

    func testQuantityConversions() {
        XCTAssertEqual(ChainCallShape.decimalWei("0xde0b6b3a7640000"), "1000000000000000000")
        XCTAssertEqual(ChainCallShape.decimalWei("42"), "42")
        XCTAssertEqual(ChainCallShape.decimalWei(nil), "0")
        XCTAssertEqual(ChainCallShape.hexQuantity(decimal: "1000000000000000000"), "0xde0b6b3a7640000")
        XCTAssertEqual(ChainCallShape.hexQuantity(decimal: "0"), "0x0")
        XCTAssertEqual(ChainCallShape.hexQuantity(UInt64(7)), "0x7")
    }

    // MARK: - MyotisChainSource gating (no live engine)

    // Retained on the instance, NOT synchronously-dropped temporaries:
    // deallocating a @MainActor object inside a test method body trips a
    // bad-free abort in the back-deployed isolated-deinit runtime
    // (deinitOnExecutorMainActorBackDeploy → TaskLocal StopLookupScope).
    // Instance-held objects deinit at teardown, which is safe.
    private var inertNode: MyotisNode!
    private var inertSource: MyotisChainSource!

    func testMyotisSourceServesTable() {
        inertNode = MyotisNode()
        inertSource = MyotisChainSource(node: inertNode)
        let source = inertSource!
        // Chains: mainnet + gnosis only.
        XCTAssertTrue(source.serves(method: "eth_gasPrice", params: [], chainID: 1))
        XCTAssertTrue(source.serves(method: "eth_gasPrice", params: [], chainID: 100))
        XCTAssertFalse(source.serves(method: "eth_gasPrice", params: [], chainID: 137))
        // Latest-tag account reads only; pending falls through.
        XCTAssertTrue(source.serves(method: "eth_getBalance", params: ["0xa", "latest"], chainID: 1))
        XCTAssertFalse(source.serves(method: "eth_getTransactionCount", params: ["0xa", "pending"], chainID: 1))
        // Block header: latest + hashes-only.
        XCTAssertTrue(source.serves(method: "eth_getBlockByNumber", params: ["latest", false], chainID: 1))
        XCTAssertFalse(source.serves(method: "eth_getBlockByNumber", params: ["latest", true], chainID: 1))
        XCTAssertFalse(source.serves(method: "eth_getBlockByNumber", params: ["0x10", false], chainID: 1))
        // Broadcast + tx lookup are served; unknown methods are not.
        XCTAssertTrue(source.serves(method: "eth_sendRawTransaction", params: ["0x02"], chainID: 1))
        XCTAssertTrue(source.serves(method: "eth_getTransactionByHash", params: ["0xh"], chainID: 100))
        XCTAssertFalse(source.serves(method: "eth_getLogs", params: [], chainID: 1))
    }

    // MARK: - MyotisKit outcome decoders (pure)

    func testAccountOutcomeDecoding() {
        XCTAssertEqual(
            MyotisAccountOutcome.decode(#"{"balanceWei":"1000","nonce":7}"#),
            .ok(balanceWei: "1000", nonce: 7)
        )
        XCTAssertEqual(
            MyotisAccountOutcome.decode(#"{"balance":"0x3e8","nonce":"0x7"}"#),
            .ok(balanceWei: "1000", nonce: 7)
        )
        guard case .unavailable = MyotisAccountOutcome.decode(#"{"error":"not synced"}"#) else {
            return XCTFail("expected unavailable")
        }
    }

    func testFeeAndGasAndBroadcastDecoding() {
        XCTAssertEqual(
            MyotisFeeOutcome.decode(#"{"gasPriceWei":"2000000000","maxPriorityFeePerGasWei":"100"}"#),
            .ok(gasPriceWei: "2000000000", maxPriorityFeePerGasWei: "100")
        )
        XCTAssertEqual(MyotisGasOutcome.decode(#"{"status":"ok","gas":21000}"#), .ok(gas: 21000))
        XCTAssertEqual(
            MyotisGasOutcome.decode(#"{"status":"revert","dataHex":"0x08c379a0"}"#),
            .revert(dataHex: "0x08c379a0")
        )
        XCTAssertEqual(
            MyotisBroadcastOutcome.decode(#"{"txHash":"0xfeed"}"#),
            .ok(txHash: "0xfeed")
        )
        guard case .failed = MyotisBroadcastOutcome.decode(#"{"error":"invalid rlp"}"#) else {
            return XCTFail("expected failed")
        }
    }
}
