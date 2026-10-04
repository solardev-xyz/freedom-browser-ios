import XCTest
@testable import Freedom

/// The Swarm node's wallet scans through the bridge: range-capped quorum
/// rounds (desktop freedom-browser #493) and the Blockscout check for a
/// span no quorum can serve (#484).
@MainActor
final class LogScanRoutingTests: XCTestCase {
    private var bundle: ChainStackBundle!
    private var transport: ScanTransport!
    private var router: ChainDataRouter!
    private var bridge: AntChainBridge!
    private var indexer: IndexStub!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    private let gnosis = AntChainBridge.chainID
    private let sender = "0x00000000000000000000000000000000000000aa"
    private let postage = "0x45a1502382541cd610cc9068e88727426b696293"
    private let deployBlock = 16_514_506
    private let head = 48_589_636

    /// Answers per host from the request's block range.
    final class ScanTransport: @unchecked Sendable {
        private let lock = NSLock()
        var respond: (_ host: String, _ from: Int, _ to: Int) -> Result<Data, Error> = { _, _, _ in
            .failure(URLError(.cannotConnectToHost))
        }
        private(set) var hits: [(host: String, from: Int, to: Int)] = []

        var closure: ChainDataRouter.Transport {
            { [self] url, body, _ in
                let params = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["params"] as? [Any]
                let filter = params?.first as? [String: Any]
                let from = LogScanRange.blockNumber(filter?["fromBlock"]) ?? -1
                let to = LogScanRange.blockNumber(filter?["toBlock"]) ?? -1
                let host = url.host ?? ""
                let respond = lock.withLock { () -> (String, Int, Int) -> Result<Data, Error> in
                    hits.append((host, from, to))
                    return self.respond
                }
                return try respond(host, from, to).get()
            }
        }

        func hits(_ host: String) -> Int { lock.withLock { hits.filter { $0.host == host }.count } }
    }

    final class IndexStub: @unchecked Sendable {
        var height: Int?
        var finishedIndexingBlocks: Any = true
        var pages: [[String: Any]] = []
        private(set) var requests: [URL] = []

        var fetch: BlockscoutTransferIndex.Fetch {
            { [self] url, _ in
                if url.path.hasSuffix("main-page/indexing-status") {
                    return try JSONSerialization.data(withJSONObject: ["finished_indexing_blocks": finishedIndexingBlocks, "indexed_blocks_ratio": "1.00"])
                }
                requests.append(url)
                if url.path.hasSuffix("main-page/blocks") {
                    guard let height else { throw URLError(.badServerResponse) }
                    return try JSONSerialization.data(withJSONObject: [["height": height], ["height": height - 1]])
                }
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let page = Int(query.first { $0.name == "page" }?.value ?? "0") ?? 0
                guard page < pages.count else { throw URLError(.badServerResponse) }
                return try JSONSerialization.data(withJSONObject: pages[page])
            }
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        bundle = try ChainStackBundle(clock: { [unowned self] in now }, orderer: { $0 })
        bundle.chainStore.updateRPCURLs(forChainID: gnosis, ["https://full.example", "https://capped50k.example", "https://capped10k.example"])
        bundle.registry.policyOverrides[gnosis] = ChainAccessPolicy.default(forChainID: gnosis)
        transport = ScanTransport()
        router = ChainDataRouter(registry: bundle.registry, transport: transport.closure, clock: { [unowned self] in now })
        indexer = IndexStub()
        router.transferIndex = BlockscoutTransferIndex(fetch: indexer.fetch)
        bridge = AntChainBridge(router: router)
    }

    // MARK: - Fixtures

    private func padded(_ address: String) -> String {
        "0x" + String(repeating: "0", count: 24) + address.dropFirst(2)
    }

    private func scanRequest(from: Int, to: Int, topics: [Any]? = nil) -> String {
        let filter: [String: Any] = [
            "address": "0xdBF3Ea6F5beE45c02255B2c26a16F300502F68da",
            "topics": topics ?? [BlockscoutTransferIndex.transferTopic, padded(sender)],
            "fromBlock": LogScanRange.hex(from),
            "toBlock": LogScanRange.hex(to),
        ]
        let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "eth_getLogs", "params": [filter]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    }

    private struct Transfer {
        let block: Int
        let tx: String
        let logIndex: Int
        let to: String
        let value: UInt64
    }

    private let transfers = [
        Transfer(block: 20_000_000, tx: "0x" + String(repeating: "1", count: 64), logIndex: 3, to: "0x45a1502382541cd610cc9068e88727426b696293", value: 1_000_000),
        Transfer(block: 41_000_000, tx: "0x" + String(repeating: "2", count: 64), logIndex: 12, to: "0x9639ae4c7a8fa9efe585738d516a3915ddd02aad", value: 25),
    ]

    private func rpcLog(_ t: Transfer) -> [String: Any] {
        [
            "address": BlockscoutTransferIndex.token,
            "topics": [BlockscoutTransferIndex.transferTopic, padded(sender), padded(t.to)],
            "data": "0x" + String(repeating: "0", count: 64 - String(t.value, radix: 16).count) + String(t.value, radix: 16),
            "blockNumber": LogScanRange.hex(t.block),
            "transactionHash": t.tx,
            "logIndex": LogScanRange.hex(t.logIndex),
            "removed": false,
        ]
    }

    private func indexItem(_ t: Transfer) -> [String: Any] {
        [
            "block_number": t.block,
            "transaction_hash": t.tx.uppercased().replacingOccurrences(of: "0X", with: "0x"),
            "log_index": t.logIndex,
            "from": ["hash": sender],
            "to": ["hash": t.to.uppercased().replacingOccurrences(of: "0X", with: "0x")],
            "token": ["address_hash": "0xdBF3Ea6F5beE45c02255B2c26a16F300502F68da", "type": "ERC-20"],
            "total": ["decimals": "16", "value": String(t.value)],
            "type": "token_transfer",
        ]
    }

    private func result(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": value])
    }

    private func rpcError(_ code: Int, _ message: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "error": ["code": code, "message": message]])
    }

    /// Today's public Gnosis RPCs: one full-history backend, two capped.
    private func publicEndpoints(logs: [Transfer]) {
        transport.respond = { [unowned self] host, from, to in
            let span = to - from + 1
            switch host {
            case "capped50k.example" where span > 50_000:
                return .success(rpcError(-32701, "exceed maximum block range: 50000"))
            case "capped10k.example" where span > 10_000:
                return .success(rpcError(35, "ranges over 10000 blocks are not supported on free plan"))
            default:
                return .success(result(logs.filter { $0.block >= from && $0.block <= to }.map(rpcLog)))
            }
        }
    }

    private func serve(_ raw: String) async throws -> [String: Any] {
        let served = await bridge.serve(raw)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(served).utf8)) as? [String: Any])
    }

    private func refusal(_ response: [String: Any]) -> (code: Int, message: String)? {
        guard let error = response["error"] as? [String: Any], let code = error["code"] as? Int else { return nil }
        return (code, error["message"] as? String ?? "")
    }

    // MARK: - Range-capped quorum

    func testCapsAreLearnedAndAntIsToldTheWidestVerifiableSpan() async throws {
        router.transferIndex = nil
        publicEndpoints(logs: transfers)
        let wide = try await serve(scanRequest(from: deployBlock, to: head))
        let reply = try XCTUnwrap(refusal(wide))
        XCTAssertEqual(reply.code, -32005)
        XCTAssertTrue(reply.message.contains("query exceeds max block range 50000"), reply.message)
        XCTAssertEqual(transport.hits.count, 3, "one round; the second has no quorum left for the span")

        // Ant narrows to it: answered by the two endpoints whose caps cover it.
        let narrow = try await serve(scanRequest(from: 20_000_000 - 100, to: 20_000_000 - 100 + 49_999))
        XCTAssertEqual((narrow["result"] as? [Any])?.count, 1)
        XCTAssertEqual(transport.hits(_: "capped10k.example"), 1, "a learned cap keeps the endpoint out of wider spans")
    }

    func testRefusalIsAnsweredWithoutAskingAnyoneOnceCapsAreKnown() async throws {
        router.transferIndex = nil
        publicEndpoints(logs: [])
        _ = try await serve(scanRequest(from: deployBlock, to: head))
        let asked = transport.hits.count
        let again = try await serve(scanRequest(from: deployBlock, to: head))
        XCTAssertEqual(refusal(again)?.code, -32005)
        XCTAssertEqual(transport.hits.count, asked, "no endpoint is asked for a span no quorum can serve")
    }

    func testLearnedCapExpires() async throws {
        router.transferIndex = nil
        publicEndpoints(logs: [])
        _ = try await serve(scanRequest(from: deployBlock, to: head))
        let capped = try XCTUnwrap(URL(string: "https://capped50k.example"))
        XCTAssertEqual(router.logRanges.servableSpan(chainID: gnosis, url: capped), 50_000)
        now += LogRangeMemory.capTTL + 1
        XCTAssertEqual(router.logRanges.servableSpan(chainID: gnosis, url: capped), .max)
    }

    /// Async: a main-actor object freed at the end of a synchronous test
    /// trips the runner's malloc check.
    func testEndpointThatHungSitsOutForTheCooldown() async {
        let memory = LogRangeMemory(clock: { [unowned self] in now })
        let url = URL(string: "https://slow.example")!
        let range = LogScanRange(
            method: "eth_getLogs", params: [["fromBlock": "0x1", "toBlock": "0x100"]],
            capOf: { AntLogScanErrors.rangeCap($0) }, rank: { AntLogScanErrors.rank($0) }
        )!
        memory.noteFailure(chainID: gnosis, url: url, range: range, error: URLError(.timedOut))
        XCTAssertEqual(memory.servableSpan(chainID: gnosis, url: url), 0)
        now += LogRangeMemory.cooldown + 1
        XCTAssertEqual(memory.servableSpan(chainID: gnosis, url: url), .max)
        memory.noteFailure(chainID: gnosis, url: url, range: range, error: WalletRPC.Error.rpc(code: -32005, message: "limit exceeded"))
        XCTAssertNil(memory.entry(chainID: gnosis, url: url)?.refusedFrom, "a reply that may be a throttle is not learned from")
    }

    // MARK: - Blockscout

    func testIndexVerifiesTheWideScanInOneRequest() async throws {
        publicEndpoints(logs: transfers)
        indexer.height = head + 64
        indexer.pages = [["items": transfers.map(indexItem), "next_page_params": NSNull()]]
        let response = try await serve(scanRequest(from: deployBlock, to: head))
        let logs = try XCTUnwrap(response["result"] as? [[String: Any]], "\(response)")
        XCTAssertEqual(logs.map { $0["transactionHash"] as? String }, transfers.map(\.tx))
        let full = transport.hits.filter { $0.host == "full.example" }
        XCTAssertEqual(full.map(\.to), [head, head], "the quorum round, then the check up to Blockscout's height")
    }

    func testIndexReadsEveryPage() async throws {
        publicEndpoints(logs: transfers)
        indexer.height = head + 64
        indexer.pages = [
            ["items": [indexItem(transfers[1])], "next_page_params": ["page": 1, "block_number": transfers[1].block]],
            ["items": [indexItem(transfers[0])], "next_page_params": NSNull()],
        ]
        let response = try await serve(scanRequest(from: deployBlock, to: head))
        XCTAssertEqual((response["result"] as? [Any])?.count, 2, "\(response)")
        XCTAssertEqual(indexer.requests.count, 3)
    }

    func testDisagreementRefusesTheWideSpan() async throws {
        publicEndpoints(logs: transfers)
        indexer.height = head + 64
        indexer.pages = [["items": [indexItem(transfers[0])], "next_page_params": NSNull()]]
        let response = try await serve(scanRequest(from: deployBlock, to: head))
        XCTAssertNil(response["result"])
        XCTAssertTrue(refusal(response)?.message.contains("query exceeds max block range 50000") == true, "\(response)")
    }

    func testAnAmountMismatchIsADisagreement() async throws {
        publicEndpoints(logs: transfers)
        indexer.height = head + 64
        var wrong = indexItem(transfers[0])
        wrong["total"] = ["decimals": "16", "value": "999"]
        indexer.pages = [["items": [wrong, indexItem(transfers[1])], "next_page_params": NSNull()]]
        let response = try await serve(scanRequest(from: deployBlock, to: head))
        XCTAssertEqual(refusal(response)?.code, -32005)
    }

    func testIndexDownRefusesAtOnce() async throws {
        publicEndpoints(logs: transfers)
        indexer.height = nil
        let response = try await serve(scanRequest(from: deployBlock, to: head))
        XCTAssertEqual(refusal(response)?.code, -32005)
        XCTAssertTrue(refusal(response)?.message.contains("50000") == true)
    }

    func testIndexStillBackFillingIsUnavailable() async throws {
        publicEndpoints(logs: transfers)
        indexer.height = head + 64
        indexer.pages = [["items": transfers.map(indexItem), "next_page_params": NSNull()]]
        for state: Any in [false, "true", NSNull()] {
            indexer.finishedIndexingBlocks = state
            let response = try await serve(scanRequest(from: deployBlock, to: head))
            XCTAssertEqual(refusal(response)?.code, -32005, "finished_indexing_blocks: \(state)")
        }
    }

    func testIndexSwitchedOffIsNeverAsked() async throws {
        publicEndpoints(logs: transfers)
        indexer.height = head + 64
        router.transferIndex?.isEnabled = { false }
        let response = try await serve(scanRequest(from: deployBlock, to: head))
        XCTAssertEqual(refusal(response)?.code, -32005)
        XCTAssertTrue(indexer.requests.isEmpty)
    }

    func testTailAboveTheIndexGoesThroughTheQuorum() async throws {
        let late = Transfer(block: head - 10, tx: "0x" + String(repeating: "3", count: 64), logIndex: 0, to: postage, value: 7)
        publicEndpoints(logs: transfers + [late])
        indexer.height = head - 20
        // Blockscout has not indexed the late transfer yet.
        indexer.pages = [["items": transfers.map(indexItem), "next_page_params": NSNull()]]
        let response = try await serve(scanRequest(from: deployBlock, to: head))
        let logs = try XCTUnwrap(response["result"] as? [[String: Any]], "\(response)")
        XCTAssertEqual(logs.map { $0["transactionHash"] as? String }, (transfers + [late]).map(\.tx))
        let tail = transport.hits.filter { $0.from == head - 20 - 64 + 1 }
        XCTAssertGreaterThanOrEqual(tail.count, 2, "the tail is verified by a quorum")
    }

    func testAnotherSenderInTheIndexIsADisagreement() async throws {
        publicEndpoints(logs: transfers)
        indexer.height = head + 64
        var foreign = indexItem(transfers[0])
        foreign["from"] = ["hash": "0x00000000000000000000000000000000000000bb"]
        indexer.pages = [["items": [foreign, indexItem(transfers[1])], "next_page_params": NSNull()]]
        let response = try await serve(scanRequest(from: deployBlock, to: head))
        XCTAssertEqual(refusal(response)?.code, -32005)
    }

    func testOnlyTheWalletScanShapeIsChecked() async throws {
        publicEndpoints(logs: transfers)
        indexer.height = head + 64
        indexer.pages = [["items": transfers.map(indexItem), "next_page_params": NSNull()]]
        let toTopic: [Any] = [BlockscoutTransferIndex.transferTopic, NSNull(), padded(sender)]
        let response = try await serve(scanRequest(from: deployBlock, to: head, topics: toTopic))
        XCTAssertEqual(refusal(response)?.code, -32005)
        XCTAssertTrue(indexer.requests.isEmpty)
    }

    func testEligibility() {
        let base: [String: Any] = [
            "address": "0xdBF3Ea6F5beE45c02255B2c26a16F300502F68da",
            "topics": [BlockscoutTransferIndex.transferTopic, padded(sender)],
            "fromBlock": "0x1", "toBlock": "0x2",
        ]
        XCTAssertEqual(BlockscoutTransferIndex.eligibleSender(chainID: 100, params: [base]), sender)
        XCTAssertNil(BlockscoutTransferIndex.eligibleSender(chainID: 1, params: [base]))
        var other = base
        other["address"] = ["0xdBF3Ea6F5beE45c02255B2c26a16F300502F68da"]
        XCTAssertNil(BlockscoutTransferIndex.eligibleSender(chainID: 100, params: [other]), "an address list is not the scan")
        other = base
        other["blockHash"] = "0xabc"
        XCTAssertNil(BlockscoutTransferIndex.eligibleSender(chainID: 100, params: [other]))
        other = base
        other["topics"] = [BlockscoutTransferIndex.transferTopic, "0x" + String(repeating: "f", count: 64)]
        XCTAssertNil(BlockscoutTransferIndex.eligibleSender(chainID: 100, params: [other]), "not a left-padded address")
    }
}
