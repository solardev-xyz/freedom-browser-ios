import SwiftData
import XCTest
@testable import Freedom

@MainActor
final class RPCRouterTests: XCTestCase {
    private var permissionContainer: ModelContainer!
    private var permissionStore: PermissionStore!

    override func setUp() async throws {
        permissionContainer = try inMemoryContainer(for: DappPermission.self)
        permissionStore = PermissionStore(context: permissionContainer.mainContext)
    }

    // MARK: - Stub infra (mirror of TransactionServiceTests' StubRPC)

    private final class StubRPC: @unchecked Sendable {
        var responses: [String: [Data]] = [:]
        private(set) var capturedBodies: [Data] = []

        var transport: WalletRPC.Transport {
            { [weak self] _, body in
                guard let self else { throw URLError(.cancelled) }
                self.capturedBodies.append(body)
                let parsed = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                let method = parsed?["method"] as? String ?? ""
                guard var queue = self.responses[method], !queue.isEmpty else {
                    throw URLError(.unknown)
                }
                let next = queue.removeFirst()
                self.responses[method] = queue
                return next
            }
        }
    }

    private func makeRouter(stub: StubRPC, chain: Chain = .gnosis) -> RPCRouter {
        let registry = ChainRegistry(mainnetPool: EthereumRPCPool(settings: SettingsStore()))
        registry.walletRPC = WalletRPC(registry: registry, transport: stub.transport)
        return RPCRouter(
            registry: registry,
            permissionStore: permissionStore,
            activeChain: { chain }
        )
    }

    private func eligibleOrigin() -> OriginIdentity {
        OriginIdentity.from(string: "https://app.uniswap.org")!
    }

    // MARK: - Ineligible origins

    func testIneligibleOriginReturnsUnauthorized() async {
        let router = makeRouter(stub: StubRPC())
        let http = OriginIdentity.from(string: "http://evil.example.com")!
        do {
            _ = try await router.handle(method: "eth_chainId", params: [], origin: http)
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(router.errorPayload(for: error).code, 4100)
        }
    }

    // MARK: - Local-only methods (no RPC)

    func testChainIdReturnsHex() async throws {
        let router = makeRouter(stub: StubRPC(), chain: .gnosis)
        let result = try await router.handle(method: "eth_chainId", params: [], origin: eligibleOrigin())
        XCTAssertEqual(result as? String, "0x64")  // 100
    }

    func testNetVersionReturnsDecimal() async throws {
        let router = makeRouter(stub: StubRPC(), chain: .gnosis)
        let result = try await router.handle(method: "net_version", params: [], origin: eligibleOrigin())
        XCTAssertEqual(result as? String, "100")
    }

    func testEthAccountsEmptyPreConnect() async throws {
        let router = makeRouter(stub: StubRPC())
        let result = try await router.handle(method: "eth_accounts", params: [], origin: eligibleOrigin())
        XCTAssertEqual(result as? [String], [])
    }

    func testEthAccountsReturnsGrantedAccount() async throws {
        permissionStore.grant(origin: "https://app.uniswap.org", account: "0xabc")
        let router = makeRouter(stub: StubRPC())
        let result = try await router.handle(method: "eth_accounts", params: [], origin: eligibleOrigin())
        XCTAssertEqual(result as? [String], ["0xabc"])
    }

    // MARK: - RPC-backed reads

    func testBlockNumberGoesThroughWalletRPC() async throws {
        let stub = StubRPC()
        stub.responses = ["eth_blockNumber": [try rpcResult("0xabc")]]
        let router = makeRouter(stub: stub)
        let result = try await router.handle(method: "eth_blockNumber", params: [], origin: eligibleOrigin())
        XCTAssertEqual(result as? String, "0xabc")
    }

    func testGetBalanceRequiresAddress() async {
        let router = makeRouter(stub: StubRPC())
        do {
            _ = try await router.handle(method: "eth_getBalance", params: [], origin: eligibleOrigin())
            XCTFail("expected invalidParams")
        } catch {
            XCTAssertEqual(router.errorPayload(for: error).code, -32602)
        }
    }

    func testGetBalancePassesAddress() async throws {
        let stub = StubRPC()
        stub.responses = ["eth_getBalance": [try rpcResult("0x0de0b6b3a7640000")]]
        let router = makeRouter(stub: stub)
        let result = try await router.handle(
            method: "eth_getBalance",
            params: ["0xabc", "latest"],
            origin: eligibleOrigin()
        )
        XCTAssertEqual(result as? String, "0x0de0b6b3a7640000")
    }

    func testEthCallPassesThroughArbitraryParams() async throws {
        let stub = StubRPC()
        stub.responses = ["eth_call": [try rpcResult("0xdeadbeef")]]
        let router = makeRouter(stub: stub)
        let callObj: [String: Any] = ["to": "0xcontract", "data": "0x70a08231"]
        let result = try await router.handle(
            method: "eth_call",
            params: [callObj, "latest"],
            origin: eligibleOrigin()
        )
        XCTAssertEqual(result as? String, "0xdeadbeef")

        // The untyped passthrough must preserve the caller's params dict.
        let body = try XCTUnwrap(stub.capturedBodies.last)
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let params = try XCTUnwrap(parsed["params"] as? [Any])
        let sentCallObj = try XCTUnwrap(params.first as? [String: Any])
        XCTAssertEqual(sentCallObj["to"] as? String, "0xcontract")
        XCTAssertEqual(sentCallObj["data"] as? String, "0x70a08231")
        XCTAssertEqual(params.last as? String, "latest")
    }

    // MARK: - Gated methods (M5.5+)

    func testConnectSigningAndSendReturnUnauthorized() async {
        let router = makeRouter(stub: StubRPC())
        let gated = [
            "eth_requestAccounts",
            "enable",
            "personal_sign",
            "eth_signTypedData_v4",
            "eth_sendTransaction",
            "wallet_switchEthereumChain",
        ]
        for method in gated {
            do {
                _ = try await router.handle(method: method, params: [], origin: eligibleOrigin())
                XCTFail("expected unauthorized for \(method)")
            } catch {
                XCTAssertEqual(router.errorPayload(for: error).code, 4100, "\(method)")
            }
        }
    }

    // MARK: - Refused methods

    func testRefusedMethodsReturnUnsupported() async {
        let router = makeRouter(stub: StubRPC())
        let refused = ["eth_sign", "eth_signTransaction", "wallet_addEthereumChain", "eth_totallyMadeUp"]
        for method in refused {
            do {
                _ = try await router.handle(method: method, params: [], origin: eligibleOrigin())
                XCTFail("expected method not supported for \(method)")
            } catch {
                XCTAssertEqual(router.errorPayload(for: error).code, 4200, "\(method)")
            }
        }
    }

    // MARK: - RPC error passthrough

    /// EIP-474 execution reverts short-circuit and pass through to the
    /// dapp so it can surface the revert reason.
    func testProviderRevertSurfacesCodeAndMessage() async throws {
        let stub = StubRPC()
        let errorEnvelope = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "error": [
                "code": -32000,
                "message": "execution reverted",
                "data": "0x08c379a000000000000000000000000000000000000000000000000000000000",
            ],
        ])
        stub.responses = ["eth_call": [errorEnvelope]]
        let router = makeRouter(stub: stub)
        do {
            _ = try await router.handle(
                method: "eth_call",
                params: [["to": "0xcontract", "data": "0x"], "latest"],
                origin: eligibleOrigin()
            )
            XCTFail("expected rpc error")
        } catch {
            let payload = router.errorPayload(for: error)
            XCTAssertEqual(payload.code, -32000)
            XCTAssertEqual(payload.message, "execution reverted")
        }
    }
}
