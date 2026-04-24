import BigInt
import XCTest
import web3
@testable import Freedom

@MainActor
final class TransactionServiceTests: XCTestCase {
    private var service: String = ""

    override func setUp() {
        service = "com.freedom.wallet.test.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        try VaultCrypto(service: service).wipe()
    }

    /// Hardhat default — known-address account 0 lets us sanity-check the
    /// signing path against real cryptographic output.
    private let hardhatMnemonic = "test test test test test test test test test test test junk"

    private func makeUnlockedVault() async throws -> Vault {
        let mnemonic = try Mnemonic(phrase: hardhatMnemonic)
        let crypto = VaultCrypto(service: service, preferred: .deviceBound)
        let vault = Vault(crypto: crypto)
        try await vault.create(mnemonic: mnemonic)
        return vault
    }

    /// Deterministic RPC responses keyed by method name. The transport
    /// records every payload the service emits so we can assert on the
    /// wire format.
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

        func decodedMethodCalls() -> [String] {
            capturedBodies.compactMap { body in
                (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["method"] as? String
            }
        }
    }

    private func rpcResult(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": value])
    }

    private func makeService(vault: Vault, stub: StubRPC) -> TransactionService {
        let registry = ChainRegistry(mainnetPool: EthereumRPCPool(settings: SettingsStore()))
        registry.walletRPC = WalletRPC(registry: registry, transport: stub.transport)
        return TransactionService(vault: vault, registry: registry)
    }

    // MARK: - prepare

    func testPrepareParallelizesCallsAndComputesMaxFee() async throws {
        let vault = try await makeUnlockedVault()
        let stub = StubRPC()
        stub.responses = [
            "eth_getTransactionCount": [try rpcResult("0xa")],  // 10
            "eth_gasPrice": [try rpcResult("0x77359400")],      // 2 gwei
            "eth_estimateGas": [try rpcResult("0x5208")],       // 21000
        ]

        let service = makeService(vault: vault, stub: stub)
        let quote = try await service.prepare(
            from: EthereumAddress("0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"),
            to: EthereumAddress("0x70997970C51812dc3A010C7d01b50e0d17dc79C8"),
            valueWei: BigUInt("de0b6b3a7640000", radix: 16)!,  // 1 xDAI
            on: .gnosis
        )

        XCTAssertEqual(quote.nonce, 10)
        XCTAssertEqual(quote.gasPrice, BigUInt(2_000_000_000))
        XCTAssertEqual(quote.gasLimit, BigUInt(21_000))
        XCTAssertEqual(quote.maxFeeWei, BigUInt(2_000_000_000) * BigUInt(21_000))

        let calls = stub.decodedMethodCalls().sorted()
        XCTAssertEqual(calls, ["eth_estimateGas", "eth_gasPrice", "eth_getTransactionCount"])
    }

    // MARK: - send

    func testSendBroadcastsSignedRawAndReturnsHash() async throws {
        let vault = try await makeUnlockedVault()
        let stub = StubRPC()
        stub.responses = [
            "eth_sendRawTransaction": [try rpcResult("0xdeadbeef")],
        ]
        let service = makeService(vault: vault, stub: stub)

        let fromHDKey = try vault.signingKey(at: .mainUser)
        let quote = TransactionService.Quote(
            from: EthereumAddress(try fromHDKey.ethereumAddress),
            nonce: 0,
            gasPrice: BigUInt(2_000_000_000),
            gasLimit: BigUInt(21_000)
        )
        let hash = try await service.send(
            to: EthereumAddress("0x70997970C51812dc3A010C7d01b50e0d17dc79C8"),
            valueWei: BigUInt("de0b6b3a7640000", radix: 16)!,
            quote: quote,
            on: .gnosis
        )
        XCTAssertEqual(hash, "0xdeadbeef")

        // Verify the wire body contained a 0x-prefixed raw-tx hex — the
        // exact bytes change per nonce/key but the shape is invariant.
        let body = try XCTUnwrap(stub.capturedBodies.last)
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let params = try XCTUnwrap(parsed["params"] as? [String])
        let raw = try XCTUnwrap(params.first)
        XCTAssertTrue(raw.hasPrefix("0x"))
        XCTAssertGreaterThan(raw.count, 150, "signed tx hex should be ≥ ~75 bytes")
    }

    // MARK: - awaitConfirmation

    func testAwaitConfirmationReturnsBlockNumberWhenSeen() async throws {
        let stub = StubRPC()
        stub.responses = [
            "eth_getTransactionByHash": [
                try rpcResult(NSNull()),             // not yet seen
                try rpcResult(NSNull()),             // still pending
                try rpcResult(["blockNumber": "0x7b"]),  // 123
            ],
        ]
        let vault = try await makeUnlockedVault()
        let service = makeService(vault: vault, stub: stub)

        let block = try await service.awaitConfirmation(
            hash: "0xaaa",
            on: .gnosis,
            pollInterval: .milliseconds(5),
            timeout: .milliseconds(500)
        )
        XCTAssertEqual(block, 123)
    }

    func testAwaitConfirmationTimesOut() async throws {
        let stub = StubRPC()
        // Always-null responses (20 of them, well beyond the ~10 polls
        // the short timeout will fit).
        stub.responses = [
            "eth_getTransactionByHash": Array(repeating: try rpcResult(NSNull()), count: 20),
        ]
        let vault = try await makeUnlockedVault()
        let service = makeService(vault: vault, stub: stub)

        do {
            _ = try await service.awaitConfirmation(
                hash: "0xaaa",
                on: .gnosis,
                pollInterval: .milliseconds(20),
                timeout: .milliseconds(100)
            )
            XCTFail("expected confirmationTimeout")
        } catch TransactionService.Error.confirmationTimeout {
            // expected
        }
    }
}
