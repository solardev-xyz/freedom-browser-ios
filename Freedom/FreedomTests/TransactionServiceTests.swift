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
            data: Data(),
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

    /// Diagnostic: EIP-155 requires v = chainId*2 + 35 + recid. For Gnosis
    /// (chainId=100) that's 235 or 236. If this test fails with v=208/209,
    /// Argent's legacy-tx signing is mis-encoding v for non-mainnet chains.
    /// We decode from raw RLP bytes since SignedTransaction.v is internal.
    /// `eth_estimateGas` precheck failure rewraps `WalletRPC.Error.insufficientFunds`
    /// as `TransactionService.Error.insufficientBalance` so the UI doesn't
    /// import `WalletRPC.Error`.
    func testPrepareMapsInsufficientFundsToDomainError() async throws {
        let vault = try await makeUnlockedVault()
        let stub = StubRPC()
        stub.responses = [
            "eth_getTransactionCount": [try rpcResult("0xa")],
            "eth_gasPrice": [try rpcResult("0x77359400")],
            "eth_estimateGas": [
                try rpcError(code: -32000, message: "err: insufficient funds for gas * price + value"),
            ],
        ]
        let service = makeService(vault: vault, stub: stub)

        do {
            _ = try await service.prepare(
                from: EthereumAddress("0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"),
                to: EthereumAddress("0x70997970C51812dc3A010C7d01b50e0d17dc79C8"),
                valueWei: BigUInt("de0b6b3a7640000", radix: 16)!,
                data: Data(),
                on: .gnosis
            )
            XCTFail("expected .insufficientBalance")
        } catch TransactionService.Error.insufficientBalance {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testSignedVIsEIP155ValidForGnosis() async throws {
        let vault = try await makeUnlockedVault()
        let hdKey = try vault.signingKey(at: .mainUser)
        let account = try EthereumAccount(
            keyStorage: HDKeyStorage(privateKey: hdKey.privateKey)
        )
        let tx = EthereumTransaction(
            from: EthereumAddress(try hdKey.ethereumAddress),
            to: EthereumAddress("0x70997970C51812dc3A010C7d01b50e0d17dc79C8"),
            value: BigUInt(10).power(15),
            data: Data(),
            nonce: 0,
            gasPrice: BigUInt(2_000_000_000),
            gasLimit: BigUInt(21_000),
            chainId: 100
        )
        let signed = try account.sign(transaction: tx)
        let raw = try XCTUnwrap(signed.raw)
        // RLP-encoded legacy tx ends with [v, r, s]. r and s each serialize
        // as 0xa0 + 32 bytes = 33 bytes. The byte before that 66-byte tail
        // is v's value (RLP single-byte for v≤127, or the byte after an
        // 0x81 prefix for v≥128 — either way the last byte IS v).
        let vByte = try XCTUnwrap(raw.dropLast(66).last)
        let v = Int(vByte)
        XCTAssertTrue(
            v == 235 || v == 236,
            "expected EIP-155 v for chainId 100 (235 or 236), got \(v) (raw last-32: \(raw.suffix(100).map { String(format: "%02x", $0) }.joined()))"
        )
    }

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
            data: Data(),
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
        // Double-0x prefix got shipped once — check specifically. A valid
        // signed tx hex never starts with "0x0".
        XCTAssertFalse(raw.hasPrefix("0x0x"))
        // After the prefix, everything must be a hex digit.
        XCTAssertTrue(
            raw.dropFirst(2).allSatisfy(\.isHexDigit),
            "body after 0x must be hex: \(raw.prefix(20))…"
        )
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
