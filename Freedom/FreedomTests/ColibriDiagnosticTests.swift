import XCTest
import Colibri
import web3
@testable import Freedom

/// One-off diagnostic to surface what sub-requests the v1.1.24 binding
/// generates for a UR.resolve eth_call. The intercepted url + type
/// disambiguates whether we hit a `prover` typing bug (binding routes a
/// proven sub-request to `eth_rpcs`) or a legitimate need for an external
/// JSON-RPC. Run via `TEST_RUNNER_COLIBRI_E2E=1`.
@MainActor
final class ColibriDiagnosticTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        if ProcessInfo.processInfo.environment["COLIBRI_E2E"] != "1" {
            throw XCTSkip("Set TEST_RUNNER_COLIBRI_E2E=1")
        }
        executionTimeAllowance = 60
        StorageBridge.registerStorage(MemoryStorage())
    }

    override func tearDown() async throws {
        StorageBridge.implementation = nil
        try await super.tearDown()
    }

    func testInspectSubRequests() async throws {
        let client = Colibri()
        client.chainId = 1
        client.provers = ["https://mainnet1.colibri-proof.tech"]
        client.zkProof = true
        client.privacyMode = .basic
        let handler = LoggingHandler()
        client.requestHandler = handler

        // UR.resolve(dnsEncode("vitalik.eth"), addr(namehash("vitalik.eth")))
        let dns = try ENSNameEncoding.dnsEncode("vitalik.eth")
        let inner = UniversalResolverABI.addrSelector + ENSNameEncoding.namehash("vitalik.eth")
        let calldata = try UniversalResolverABI.encodeResolve(name: dns, callData: inner)
        let paramsJSON = try JSONSerialization.data(withJSONObject: [
            ["to": UniversalResolverABI.address.asString(), "data": "0x" + calldata.map { String(format: "%02x", $0) }.joined()],
            "latest",
        ])
        let params = String(data: paramsJSON, encoding: .utf8) ?? "[]"

        _ = try? await client.rpc(method: "eth_call", params: params)

        print("=== Colibri sub-request log ===")
        for req in await handler.requests {
            print("type=\(req.type ?? "<nil>") method=\(req.method) url=\(req.url)")
        }
        print("=== \(await handler.requests.count) sub-requests captured ===")
    }
}

private actor LoggingHandler: RequestHandler {
    private(set) var requests: [DataRequest] = []
    func handleRequest(_ request: DataRequest) async throws -> Data {
        requests.append(request)
        // Throwing makes the C lib see "no server response" and continue
        // its retry/error path, surfacing the exhaustive set of sub-
        // requests it would have made.
        throw DiagnosticAbort()
    }
}

private struct DiagnosticAbort: Error {}

private final class MemoryStorage: ColibriStorage {
    private var store: [String: Data] = [:]
    func get(key: String) -> Data? { store[key] }
    func set(key: String, value: Data) { store[key] = value }
    func delete(key: String) { store.removeValue(forKey: key) }
}
