import XCTest
import web3
@testable import Freedom

/// The Swarm node's chain requests through the chain-data router —
/// desktop `ant-chain-bridge.test.js` / `ant-log-scan-routing.test.js`
/// parity over ant's FFI transport contract.
@MainActor
final class AntChainBridgeTests: XCTestCase {
    private var bundle: ChainStackBundle!
    private var transport: ChainDataRouterTests.Transport!
    private var router: ChainDataRouter!
    private var bridge: AntChainBridge!

    private let gnosis = AntChainBridge.chainID

    override func setUp() async throws {
        try await super.setUp()
        bundle = try ChainStackBundle(orderer: { $0 })
        bundle.chainStore.updateRPCURLs(forChainID: gnosis, ["https://g1.example", "https://g2.example"])
        transport = ChainDataRouterTests.Transport()
        router = ChainDataRouter(registry: bundle.registry, transport: transport.closure)
        bridge = AntChainBridge(router: router)
    }

    // MARK: - Helpers

    private func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func request(_ method: String, _ params: [Any] = [], id: Any = 7) -> String {
        json(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func result(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": value])
    }

    private func rpcError(_ code: Int, _ message: String, data: String? = nil) -> Data {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        return try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "error": error])
    }

    private func serve(_ raw: String) async throws -> [String: Any] {
        let served = await bridge.serve(raw)
        let response = try XCTUnwrap(served)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }

    private func assertCode(_ raw: String, _ expected: Int, line: UInt = #line) async throws {
        let response = try await serve(raw)
        XCTAssertEqual(error(of: response)?.code, expected, line: line)
    }

    private func error(of response: [String: Any]) -> (code: Int, message: String, data: String?)? {
        guard let error = response["error"] as? [String: Any], let code = error["code"] as? Int else { return nil }
        return (code, error["message"] as? String ?? "", error["data"] as? String)
    }

    /// A signed-looking transaction: real RLP, dummy signature.
    private func signedTransaction(chainID: Int, typed: Bool) -> String {
        let to = Data(repeating: 0x11, count: 20)
        let sig: [Any] = [0, Data([0x01]), Data([0x02])]
        let body: Data
        if typed {
            body = Data([0x02]) + RLP.encode([chainID, 0, 1, 1, 21_000, to, 0, Data(), [Any](), sig[0], sig[1], sig[2]])!
        } else {
            body = RLP.encode([0, 1, 21_000, to, 0, Data(), chainID * 2 + 35, sig[1], sig[2]])!
        }
        return "0x" + body.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Contract

    func testReadIsRoutedAndEchoesTheRequestID() async throws {
        transport.answers["g1.example"] = .success(result("0x10"))
        let response = try await serve(request("eth_blockNumber", id: "abc"))
        XCTAssertEqual(response["result"] as? String, "0x10")
        XCTAssertEqual(response["id"] as? String, "abc")
        XCTAssertEqual(transport.hits, ["g1.example"])
        // Ant's requests carry `"id": 1`, which JSONSerialization hands
        // over as an NSNumber that also reads as a Bool.
        for id: Any in [1, 0, 42] {
            let numbered = try await serve(request("eth_blockNumber", id: id))
            XCTAssertEqual(numbered["result"] as? String, "0x10", "id \(id)")
            XCTAssertEqual((numbered["id"] as? NSNumber)?.intValue, (id as? Int))
        }
        try await assertCode(request("eth_blockNumber", id: true), -32600)
        try await assertCode(request("eth_blockNumber", id: 1.5), -32600)
    }

    func testRejectsWhatAntNeverSends() async throws {
        try await assertCode(request("eth_getBlockByNumber", ["latest", false]), -32601)
        try await assertCode(request("web3_clientVersion"), -32601)
        try await assertCode(json(["jsonrpc": "2.0", "id": 1, "method": "eth_blockNumber"]), -32600)
        try await assertCode(json([["jsonrpc": "2.0", "id": 1, "method": "eth_blockNumber", "params": []]]), -32600)
        try await assertCode("{not json", -32700)
        XCTAssertTrue(transport.hits.isEmpty, "nothing reached an endpoint")
    }

    func testBroadcastAcceptsOnlySignedGnosisTransactions() async throws {
        try await assertCode(request("eth_sendRawTransaction", [signedTransaction(chainID: 1, typed: true)]), -32602)
        try await assertCode(request("eth_sendRawTransaction", ["0x02c0"]), -32602)
        try await assertCode(request("eth_sendRawTransaction", []), -32602)
        XCTAssertTrue(transport.hits.isEmpty)

        transport.answers["g1.example"] = .success(result("0x" + String(repeating: "ab", count: 32)))
        let response = try await serve(request("eth_sendRawTransaction", [signedTransaction(chainID: gnosis, typed: true)]))
        XCTAssertEqual(response["result"] as? String, "0x" + String(repeating: "ab", count: 32))
        XCTAssertEqual(transport.hits, ["g1.example"])
        let legacy = try await serve(request("eth_sendRawTransaction", [signedTransaction(chainID: gnosis, typed: false)]))
        XCTAssertNotNil(legacy["result"])
    }

    func testEndpointErrorsReachAntWithTheirCodeExceptTheFallbackCode() async throws {
        transport.answers["g1.example"] = .success(rpcError(-32000, "nonce too low"))
        transport.answers["g2.example"] = .success(rpcError(-32000, "nonce too low"))
        let replyResponse = try await serve(request("eth_getTransactionCount", ["0x11", "latest"]))
        let reply = try XCTUnwrap(error(of: replyResponse))
        XCTAssertEqual(reply.code, -32002, "-32000 would make ant replay the request against its pinned URL")
        XCTAssertTrue(reply.message.contains("nonce too low"), reply.message)

        transport.answers["g1.example"] = .success(rpcError(3, "execution reverted", data: "0x08c379a0"))
        let revertResponse = try await serve(request("eth_call", [["to": "0x11", "data": "0x"], "latest"]))
        let revert = try XCTUnwrap(error(of: revertResponse))
        XCTAssertEqual(revert.code, 3)
        XCTAssertEqual(revert.message, "Execution reverted")
        XCTAssertEqual(revert.data, "0x08c379a0")
    }

    func testTransportFailureIsAnErrorNeverAnEmptyResult() async throws {
        let replyResponse = try await serve(request("eth_getBalance", ["0x11", "latest"]))
        let reply = try XCTUnwrap(error(of: replyResponse))
        XCTAssertEqual(reply.code, -32002)
        XCTAssertTrue(reply.message.hasPrefix("Chain request failed"), reply.message)
    }

    func testResponseSanitizesURLs() {
        XCTAssertEqual(AntChainBridge.sanitize("failed https://rpc.example/v1/SECRET; retry\n now"), "failed [url]; retry now")
    }

    // MARK: - eth_getLogs ranking (desktop's one rule)

    func testRangeLimitEndsTheWalkAndReachesAntVerbatim() async throws {
        transport.answers["g1.example"] = .success(rpcError(-32005, "query exceeds max block range 50000"))
        transport.answers["g2.example"] = .success(result([]))
        let replyResponse = try await serve(request("eth_getLogs", [["fromBlock": "0x1", "toBlock": "0xffff"]]))
        let reply = try XCTUnwrap(error(of: replyResponse))
        XCTAssertEqual(reply.code, -32005)
        XCTAssertTrue(reply.message.contains("query exceeds max block range 50000"), reply.message)
        XCTAssertEqual(transport.hits, ["g1.example"], "a request-level failure never asks the next endpoint")
    }

    func testThrottleIsStrippedOfAntsNeedles() async throws {
        transport.answers["g1.example"] = .success(rpcError(-32005, "rate limit exceeded"))
        transport.answers["g2.example"] = .success(rpcError(-32005, "rate limit exceeded"))
        let replyResponse = try await serve(request("eth_getLogs", [["fromBlock": "0x1"]]))
        let reply = try XCTUnwrap(error(of: replyResponse))
        XCTAssertEqual(reply.code, -32005)
        XCTAssertEqual(reply.message, "Chain request failed: endpoint unavailable")
        XCTAssertEqual(transport.hits.count, 2, "a throttle falls through to the next endpoint")
    }

    func testTimeoutIsWordedSoAntHalvesItsWindow() async throws {
        transport.answers["g1.example"] = .failure(URLError(.timedOut))
        transport.answers["g2.example"] = .failure(URLError(.timedOut))
        let replyResponse = try await serve(request("eth_getLogs", [["fromBlock": "0x1"]]))
        let reply = try XCTUnwrap(error(of: replyResponse))
        XCTAssertTrue(reply.message.contains("query timeout"), reply.message)
    }

    func testHintIsKeptOverEndpointFailuresButKeepsWalking() async throws {
        transport.answers["g1.example"] = .success(rpcError(-32005, "limit exceeded"))
        transport.answers["g2.example"] = .success(rpcError(-32603, "internal error"))
        let replyResponse = try await serve(request("eth_getLogs", [["fromBlock": "0x1"]]))
        let reply = try XCTUnwrap(error(of: replyResponse))
        XCTAssertEqual(reply.code, -32005)
        XCTAssertTrue(reply.message.contains("limit exceeded"), reply.message)
        XCTAssertEqual(transport.hits.count, 2)
    }

    func testLogScanUsesTheWideDirectBudget() async throws {
        transport.answers["g1.example"] = .success(result([]))
        _ = try await serve(request("eth_getLogs", [["fromBlock": "0x1"]]))
        XCTAssertEqual(transport.timeouts.last, AntChainBridge.logScanDirectTimeout)
        _ = try await serve(request("eth_blockNumber"))
        XCTAssertNotEqual(transport.timeouts.last, AntChainBridge.logScanDirectTimeout)
    }

    func testRanking() {
        func rank(_ code: Int?, _ message: String) -> ChainDataRouter.ErrorRank {
            let error: Swift.Error = code.map { WalletRPC.Error.rpc(code: $0, message: message) } ?? URLError(.cannotConnectToHost)
            return AntLogScanErrors.rank(error)
        }
        XCTAssertEqual(rank(-32005, "query exceeds max block range 50000"), .request)
        XCTAssertEqual(rank(-32005, "query returned more than 10000 results"), .request)
        XCTAssertEqual(rank(-32005, "limit exceeded"), .hint)
        XCTAssertEqual(rank(-32005, "project ID request rate exceeded"), .endpoint)
        XCTAssertEqual(rank(-32000, "block range extends beyond current head block"), .endpoint)
        XCTAssertEqual(rank(-32603, "internal error"), .endpoint)
        XCTAssertEqual(rank(nil, "connection refused"), .endpoint)
        XCTAssertEqual(rank(-32603, "request timed out"), .timeout)
        XCTAssertEqual(AntLogScanErrors.rank(URLError(.timedOut)), .timeout)
    }

    // MARK: - Background admission

    func testBackgroundReadNeverQueuesBehindMyotis() async throws {
        let myotis = ChainDataRouterTests.FakeSource(.myotis)
        myotis.served["eth_blockNumber"] = "0x99"
        bundle.registry.verifiedSources = [myotis]
        // Someone interactive holds the single Myotis slot.
        _ = router.admission.acquireMyotis(chainID: gnosis)
        transport.answers["g1.example"] = .success(result("0x10"))
        let response = try await serve(request("eth_blockNumber"))
        XCTAssertEqual(response["result"] as? String, "0x10", "served by the direct tier")
        XCTAssertEqual(router.admission.myotisQueueDepth(chainID: gnosis), 0)
        XCTAssertTrue(myotis.calls.isEmpty)
        router.admission.releaseMyotis(chainID: gnosis)
    }

    // MARK: - Signed transaction inspection

    func testInspectorReadsChainIDOnlyFromSignedTransactions() {
        XCTAssertEqual(SignedTransactionInspector.chainID(rawTransaction: signedTransaction(chainID: 100, typed: true)), 100)
        XCTAssertEqual(SignedTransactionInspector.chainID(rawTransaction: signedTransaction(chainID: 1, typed: true)), 1)
        XCTAssertEqual(SignedTransactionInspector.chainID(rawTransaction: signedTransaction(chainID: 100, typed: false)), 100)
        let unsigned = "0x02" + RLP.encode([100, 0, 1, 1, 21_000, Data(repeating: 0x11, count: 20), 0, Data(), [Any]()])!
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertNil(SignedTransactionInspector.chainID(rawTransaction: unsigned))
        XCTAssertNil(SignedTransactionInspector.chainID(rawTransaction: "0x"))
        XCTAssertNil(SignedTransactionInspector.chainID(rawTransaction: "zz"))
    }
}
