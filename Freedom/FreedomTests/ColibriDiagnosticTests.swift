import XCTest
import Colibri
import web3
@testable import Freedom

/// Diagnostic harness that logs the sub-requests Colibri's verifier
/// emits for a UR.resolve `eth_call` (type + method + url + payload).
/// Originally written to identify the `eth_getCode` / `eth_getProof`
/// fetches that PAP mode routes through `eth_rpcs` — kept as a tool for
/// inspecting verifier behavior across binding upgrades. Run via
/// `TEST_RUNNER_COLIBRI_E2E=1`.
@MainActor
final class ColibriDiagnosticTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        if ProcessInfo.processInfo.environment["COLIBRI_E2E"] != "1" {
            throw XCTSkip("Set TEST_RUNNER_COLIBRI_E2E=1")
        }
        executionTimeAllowance = 120
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
        // Deliberately leave `eth_rpcs` empty so URL-less sub-requests
        // surface in the log — that's what this harness inspects.
        let handler = LoggingHandler()
        client.requestHandler = handler

        // UR.resolve(dnsEncode("vitalik.eth"), addr(namehash("vitalik.eth")))
        let dns = try ENSNameEncoding.dnsEncode("vitalik.eth")
        let inner = UniversalResolverABI.addrSelector + ENSNameEncoding.namehash("vitalik.eth")
        let calldata = try UniversalResolverABI.encodeResolve(name: dns, callData: inner)
        let paramsJSON = try JSONSerialization.data(withJSONObject: [
            ["to": UniversalResolverABI.address.asString(), "data": calldata.web3.hexString],
            "latest",
        ])
        let params = String(data: paramsJSON, encoding: .utf8) ?? "[]"

        _ = try? await client.rpc(method: "eth_call", params: params)

        print("=== Colibri sub-request log (\(await handler.log.count) requests) ===")
        for (i, entry) in await handler.log.enumerated() {
            print("[\(i)] type=\(entry.type ?? "<nil>") method=\(entry.method) url=\(entry.url.isEmpty ? "<EMPTY>" : entry.url)")
            if let payload = entry.payloadJSON {
                print("     payload=\(payload)")
            }
        }
        print("=== end ===")
    }
}

private struct LogEntry {
    let type: String?
    let method: String
    let url: String
    let payloadJSON: String?
}

/// Forwards any request with a real URL to its server (so the proof
/// flow proceeds), logs every request including its payload, and throws
/// for URL-less requests (the broken `eth_rpc` sub-request) after logging.
private actor LoggingHandler: RequestHandler {
    private(set) var log: [LogEntry] = []

    func handleRequest(_ request: DataRequest) async throws -> Data {
        let payloadJSON = request.payload.flatMap { p -> String? in
            guard let d = try? JSONSerialization.data(withJSONObject: p) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        log.append(LogEntry(
            type: request.type, method: request.method,
            url: request.url, payloadJSON: payloadJSON
        ))
        guard let url = URL(string: request.url), url.scheme != nil else {
            throw DiagnosticAbort()
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.uppercased()
        if let payload = request.payload {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }
        let (data, _) = try await URLSession.shared.data(for: urlRequest)
        return data
    }
}

private struct DiagnosticAbort: Error {}

private final class MemoryStorage: ColibriStorage {
    private var store: [String: Data] = [:]
    func get(key: String) -> Data? { store[key] }
    func set(key: String, value: Data) { store[key] = value }
    func delete(key: String) { store.removeValue(forKey: key) }
}
