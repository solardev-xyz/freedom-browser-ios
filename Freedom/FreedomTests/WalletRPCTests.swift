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

    /// Wraps a JSON-RPC result value in the envelope the client expects.
    private func rpcResult(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "result": value,
        ])
    }

    private func rpcError(code: Int, message: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "error": ["code": code, "message": message],
        ])
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

    func testRPCErrorDoesNotFallThrough() async throws {
        // An explicit JSON-RPC error envelope is deterministic across
        // providers — bubble up, don't pound the next URL.
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
