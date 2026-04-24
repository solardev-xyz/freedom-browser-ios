import XCTest
import web3
@testable import Freedom

@MainActor
final class MessageSignerTests: XCTestCase {
    private var service: String = ""
    private let hardhatMnemonic = "test test test test test test test test test test test junk"
    private let account0 = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"

    override func setUp() {
        service = "com.freedom.wallet.test.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        try VaultCrypto(service: service).wipe()
    }

    private func makeUnlockedVault() async throws -> Vault {
        let mnemonic = try Mnemonic(phrase: hardhatMnemonic)
        let crypto = VaultCrypto(service: service, preferred: .deviceBound)
        let vault = Vault(crypto: crypto)
        try await vault.create(mnemonic: mnemonic)
        return vault
    }

    // MARK: - personal_sign

    /// Sign, then recover via KeyUtil and assert the recovered address
    /// matches — proves the signature is cryptographically correct without
    /// hardcoding a vector that could drift with the library.
    func testPersonalSignRecoversCorrectAddress() async throws {
        let vault = try await makeUnlockedVault()
        let message = Data("Hello, Freedom".utf8)

        let signatureHex = try MessageSigner.signPersonalMessage(message, vault: vault)
        let sigBytes = try XCTUnwrap(signatureHex.web3.hexData)
        XCTAssertEqual(sigBytes.count, 65)

        // Reconstruct the EIP-191 hash the signature covers.
        let prefix = "\u{19}Ethereum Signed Message:\n\(message.count)"
        var prefixed = Data(prefix.utf8)
        prefixed.append(message)
        let hash = prefixed.web3.keccak256

        let recovered = try KeyUtil.recoverPublicKey(message: hash, signature: sigBytes)
        XCTAssertEqual(recovered.lowercased(), account0)
    }

    /// The v byte must be 27 or 28 for a legacy `personal_sign` (no EIP-155
    /// chain-ID suffix) — guards against a regression back to v=0/1.
    func testPersonalSignVByteIs27Or28() async throws {
        let vault = try await makeUnlockedVault()
        let signatureHex = try MessageSigner.signPersonalMessage(Data("x".utf8), vault: vault)
        let sigBytes = try XCTUnwrap(signatureHex.web3.hexData)
        let v = sigBytes.last!
        XCTAssertTrue(v == 27 || v == 28, "expected legacy v in {27, 28}, got \(v)")
    }

    // MARK: - eth_signTypedData_v4

    /// EIP-712 v4 round-trip: parse a realistic typed-data JSON string the
    /// way a dapp would send it, sign, recover, assert. Dapps send either
    /// an object or a string for the second param — this covers the string
    /// path; bridge decodes both.
    func testTypedDataRecoversCorrectAddress() async throws {
        let vault = try await makeUnlockedVault()
        let json = #"""
        {
          "types": {
            "EIP712Domain": [
              {"name": "name", "type": "string"},
              {"name": "version", "type": "string"},
              {"name": "chainId", "type": "uint256"}
            ],
            "Person": [
              {"name": "name", "type": "string"},
              {"name": "wallet", "type": "address"}
            ]
          },
          "primaryType": "Person",
          "domain": {
            "name": "Test App",
            "version": "1",
            "chainId": 100
          },
          "message": {
            "name": "Alice",
            "wallet": "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
          }
        }
        """#
        let typed = try JSONDecoder().decode(TypedData.self, from: Data(json.utf8))

        let signatureHex = try MessageSigner.signTypedData(typed, vault: vault)
        let sigBytes = try XCTUnwrap(signatureHex.web3.hexData)
        XCTAssertEqual(sigBytes.count, 65)

        let hash = try typed.signableHash()
        let recovered = try KeyUtil.recoverPublicKey(message: hash, signature: sigBytes)
        XCTAssertEqual(recovered.lowercased(), account0)
    }
}
