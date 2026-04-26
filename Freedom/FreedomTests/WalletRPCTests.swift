import XCTest
@testable import Freedom

@MainActor
final class WalletRPCTests: XCTestCase {
    /// Stub transport that dispatches on URL. Each URL is configured with
    /// either a canned response body or a thrown error. Records call order
    /// for fall-through assertions. Access is serial because the whole
    /// test case runs on @MainActor and the transport closure is only
    /// invoked during awaits — no lock needed.
    private final class StubTransport: @unchecked Sendable {
        var responses: [URL: Result<Data, Error>] = [:]
        private(set) var callLog: [URL] = []

        var transport: WalletRPC.Transport {
            { [weak self] url, _ in
                self?.callLog.append(url)
                guard let outcome = self?.responses[url] else {
                    throw URLError(.unknown)
                }
                return try outcome.get()
            }
        }
    }

    private func makeRegistry() -> ChainRegistry {
        // For tests, Mainnet goes through this empty-settings pool. We never
        // actually call Mainnet in these tests — all assertions target Gnosis
        // whose URLs are hardcoded.
        ChainRegistry(mainnetPool: EthereumRPCPool(settings: SettingsStore()))
    }

    private var gnosisURLs: [URL] { ChainRegistry.gnosisURLs }

    func testFirstProviderSuccess() async throws {
        let stub = StubTransport()
        stub.responses[gnosisURLs[0]] = .success(try rpcResult("0x10f2c"))
        let rpc = WalletRPC(registry: makeRegistry(), transport: stub.transport)

        let block = try await rpc.blockNumber(on: .gnosis)
        XCTAssertEqual(block, "0x10f2c")
        XCTAssertEqual(stub.callLog, [gnosisURLs[0]])
    }

    func testFallsThroughOnTransportError() async throws {
        let stub = StubTransport()
        stub.responses[gnosisURLs[0]] = .failure(URLError(.notConnectedToInternet))
        stub.responses[gnosisURLs[1]] = .success(try rpcResult("0x10f2c"))
        let rpc = WalletRPC(registry: makeRegistry(), transport: stub.transport)

        let block = try await rpc.blockNumber(on: .gnosis)
        XCTAssertEqual(block, "0x10f2c")
        XCTAssertEqual(stub.callLog, [gnosisURLs[0], gnosisURLs[1]])
    }

    func testFallsThroughOnInvalidEnvelope() async throws {
        // Provider returns valid JSON but neither `result` nor `error` — some
        // public RPCs do this during their bad moments. Retry the next.
        let stub = StubTransport()
        stub.responses[gnosisURLs[0]] = .success(Data("{\"jsonrpc\":\"2.0\",\"id\":1}".utf8))
        stub.responses[gnosisURLs[1]] = .success(try rpcResult("0x10f2c"))
        let rpc = WalletRPC(registry: makeRegistry(), transport: stub.transport)

        let block = try await rpc.blockNumber(on: .gnosis)
        XCTAssertEqual(block, "0x10f2c")
    }

    /// `-32602 invalid params` short-circuits — every well-behaved server
    /// would reject the same way.
    func testInvalidParamsShortCircuits() async throws {
        let stub = StubTransport()
        stub.responses[gnosisURLs[0]] = .success(try rpcError(code: -32602, message: "invalid params"))
        stub.responses[gnosisURLs[1]] = .success(try rpcResult("0x10f2c"))
        let rpc = WalletRPC(registry: makeRegistry(), transport: stub.transport)

        do {
            let _: String = try await rpc.call("eth_blockNumber", params: [String](), on: .gnosis)
            XCTFail("expected .rpc error")
        } catch WalletRPC.Error.rpc(let code, let message) {
            XCTAssertEqual(code, -32602)
            XCTAssertEqual(message, "invalid params")
            XCTAssertEqual(stub.callLog, [gnosisURLs[0]])
        }
    }

    /// EIP-474 execution revert (`error.data` populated) short-circuits —
    /// protocol-deterministic answer.
    func testExecutionRevertShortCircuits() async throws {
        let stub = StubTransport()
        stub.responses[gnosisURLs[0]] = .success(
            try rpcError(code: 3, message: "execution reverted", dataHex: "0x08c379a0...")
        )
        stub.responses[gnosisURLs[1]] = .success(try rpcResult("0xdeadbeef"))
        let rpc = WalletRPC(registry: makeRegistry(), transport: stub.transport)

        do {
            let _: String = try await rpc.call("eth_call", params: [String](), on: .gnosis)
            XCTFail("expected .rpc error")
        } catch WalletRPC.Error.rpc(let code, _) {
            XCTAssertEqual(code, 3)
            XCTAssertEqual(stub.callLog, [gnosisURLs[0]])
        }
    }

    /// Provider-quirk error envelopes without `data` iterate — they may
    /// be Cloudflare's `-32603` or Ankr's `-32000` which the next provider
    /// won't replicate.
    func testNonDeterministicRPCErrorIterates() async throws {
        let stub = StubTransport()
        stub.responses[gnosisURLs[0]] = .success(try rpcError(code: -32603, message: "internal error"))
        stub.responses[gnosisURLs[1]] = .success(try rpcResult("0x10f2c"))
        let rpc = WalletRPC(registry: makeRegistry(), transport: stub.transport)

        let block = try await rpc.blockNumber(on: .gnosis)
        XCTAssertEqual(block, "0x10f2c")
        XCTAssertEqual(stub.callLog, [gnosisURLs[0], gnosisURLs[1]])
    }

    func testUnauthorizedRPCErrorIterates() async throws {
        let stub = StubTransport()
        stub.responses[gnosisURLs[0]] = .success(try rpcError(code: -32000, message: "API key required"))
        stub.responses[gnosisURLs[1]] = .success(try rpcResult("0x10f2c"))
        let rpc = WalletRPC(registry: makeRegistry(), transport: stub.transport)

        let block = try await rpc.blockNumber(on: .gnosis)
        XCTAssertEqual(block, "0x10f2c")
    }

    /// Insufficient-funds messages from `eth_estimateGas` short-circuit
    /// with a typed domain error so the send-flow surfaces a real
    /// message instead of a generic "Check connection".
    func testInsufficientFundsShortCircuitsWithTypedError() async throws {
        let stub = StubTransport()
        stub.responses[gnosisURLs[0]] = .success(
            try rpcError(code: -32000, message: "err: insufficient funds for gas * price + value: address ...")
        )
        stub.responses[gnosisURLs[1]] = .success(try rpcResult("0x5208"))
        let rpc = WalletRPC(registry: makeRegistry(), transport: stub.transport)

        do {
            let _: String = try await rpc.estimateGas(
                from: "0xabc", to: "0xdef", valueHex: "0x1", dataHex: "0x", on: .gnosis
            )
            XCTFail("expected .insufficientFunds")
        } catch WalletRPC.Error.insufficientFunds(let message) {
            XCTAssertTrue(message.lowercased().contains("insufficient funds"))
            XCTAssertEqual(stub.callLog, [gnosisURLs[0]])
        }
    }

    /// A JSON-RPC error envelope means the provider responded correctly
    /// per spec — that's transport health, not a quarantine signal.
    func testRPCErrorDoesNotPoisonQuarantine() async throws {
        let pool = EthereumRPCPool(settings: SettingsStore())
        let registry = ChainRegistry(mainnetPool: pool)
        let mainnetURLs = pool.availableProviders()
        XCTAssertGreaterThanOrEqual(mainnetURLs.count, 2)

        let stub = StubTransport()
        stub.responses[mainnetURLs[0]] = .success(try rpcError(code: -32603, message: "internal error"))
        stub.responses[mainnetURLs[1]] = .success(try rpcResult("0x10f2c"))
        let rpc = WalletRPC(registry: registry, transport: stub.transport)

        let _ = try await rpc.blockNumber(on: .mainnet)

        XCTAssertEqual(
            Set(pool.availableProviders()), Set(mainnetURLs),
            "RPC errors must not feed quarantine — a provider returning JSON-RPC error is transport-healthy"
        )
    }

    /// Transport errors (network / DNS / TLS / 5xx) DO mark provider
    /// failure — that's exactly the signal quarantine wants.
    func testTransportErrorPoisonsQuarantine() async throws {
        let pool = EthereumRPCPool(settings: SettingsStore())
        let registry = ChainRegistry(mainnetPool: pool)
        let mainnetURLs = pool.availableProviders()
        XCTAssertGreaterThanOrEqual(mainnetURLs.count, 2)

        let stub = StubTransport()
        stub.responses[mainnetURLs[0]] = .failure(URLError(.cannotConnectToHost))
        stub.responses[mainnetURLs[1]] = .success(try rpcResult("0x10f2c"))
        let rpc = WalletRPC(registry: registry, transport: stub.transport)

        let _ = try await rpc.blockNumber(on: .mainnet)

        XCTAssertFalse(
            pool.availableProviders().contains(mainnetURLs[0]),
            "transport-failed provider should be quarantined"
        )
    }

    func testAllRPCErrorsThrowAllProvidersFailed() async throws {
        let stub = StubTransport()
        for url in gnosisURLs {
            stub.responses[url] = .success(try rpcError(code: -32603, message: "internal error"))
        }
        let rpc = WalletRPC(registry: makeRegistry(), transport: stub.transport)

        do {
            let _ = try await rpc.blockNumber(on: .gnosis)
            XCTFail("expected .allProvidersFailed")
        } catch WalletRPC.Error.allProvidersFailed(let errors) {
            XCTAssertEqual(errors.count, gnosisURLs.count)
            XCTAssertEqual(stub.callLog, gnosisURLs)
        }
    }

    func testAllProvidersFailedThrows() async throws {
        let stub = StubTransport()
        for url in gnosisURLs {
            stub.responses[url] = .failure(URLError(.timedOut))
        }
        let rpc = WalletRPC(registry: makeRegistry(), transport: stub.transport)

        do {
            let _ = try await rpc.blockNumber(on: .gnosis)
            XCTFail("expected .allProvidersFailed")
        } catch WalletRPC.Error.allProvidersFailed(let errors) {
            XCTAssertEqual(errors.count, gnosisURLs.count)
            XCTAssertEqual(stub.callLog, gnosisURLs)
        }
    }

    /// A cancelled task bails out at the top of the next iteration
    /// instead of walking every provider.
    func testCooperativeCancellationBailsAfterFirstAttempt() async throws {
        let log = URLLog()
        let blocking: WalletRPC.Transport = { url, _ in
            log.append(url)
            try await Task.sleep(for: .seconds(60))
            return Data()
        }
        let rpc = WalletRPC(registry: makeRegistry(), transport: blocking)

        let task = Task { try await rpc.blockNumber(on: .gnosis) }
        // Poll instead of fixed sleep — slow CI may not have entered the
        // first transport await yet at 50ms, which would let cancel arrive
        // before any provider is logged.
        for _ in 0..<100 where log.urls.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        _ = await task.result

        XCTAssertEqual(log.urls.count, 1)
    }

    func testBalanceTypedCallEncodesCorrectParams() async throws {
        // Capture the outgoing body and verify the wire format — protects
        // against regressions where the params array shape drifts.
        let captured = CapturedRequest()
        let stub = StubTransport()
        stub.responses[gnosisURLs[0]] = .success(try rpcResult("0x8ac7230489e80000"))
        let rpc = WalletRPC(registry: makeRegistry(), transport: { url, body in
            captured.url = url
            captured.body = body
            return try await stub.transport(url, body)
        })

        let balance = try await rpc.balance(of: "0xabc", on: .gnosis)
        XCTAssertEqual(balance, "0x8ac7230489e80000")
        let json = try XCTUnwrap(captured.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(json["method"] as? String, "eth_getBalance")
        XCTAssertEqual(json["params"] as? [String], ["0xabc", "latest"])
        XCTAssertEqual(json["jsonrpc"] as? String, "2.0")
    }
}

private final class CapturedRequest: @unchecked Sendable {
    var url: URL?
    var body: Data?
}

private final class URLLog: @unchecked Sendable {
    var urls: [URL] = []
    func append(_ url: URL) { urls.append(url) }
}
