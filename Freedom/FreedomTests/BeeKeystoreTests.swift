import XCTest
@testable import Freedom

/// `BeeKeystore` is the thin V3-format wrapper Bee reads on boot. Tests
/// validate two contracts:
///   - encrypt → decrypt round-trips recover the input private key (covers
///     scrypt + AES-CTR + MAC plumbing end-to-end);
///   - the JSON shape carries the exact fields Bee's Go decoder requires
///     (`bee/v2/pkg/keystore/file/key.go`), so a smoke test against a real
///     Bee node is expected to succeed without further byte-level checks.
final class BeeKeystoreTests: XCTestCase {
    /// 32-byte fixture private key. Value is arbitrary; we just need a stable
    /// secp256k1-valid scalar to drive the round-trip.
    private let fixturePrivateKey = Data(
        hex: "0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    )!
    private let fixturePassword = "correct horse battery staple"
    /// Stand-in for the unprefixed Ethereum address. The encoder doesn't
    /// validate the value — it only writes it into the JSON — so any
    /// 40-char hex string is fine for tests that don't check the field.
    private let fixtureAddress = "abcdef0123456789abcdef0123456789abcdef01"

    private func encryptFixture(id: UUID = UUID()) throws -> Data {
        try BeeKeystore.encrypt(
            privateKey: fixturePrivateKey,
            password: fixturePassword,
            address: fixtureAddress,
            id: id
        )
    }

    // MARK: - Round-trip

    func testRoundTripRecoversPrivateKey() throws {
        let json = try encryptFixture()
        let recovered = try BeeKeystore.decrypt(json, password: fixturePassword)
        XCTAssertEqual(recovered, fixturePrivateKey)
    }

    /// A wrong password must fail before we hand back garbage cleartext —
    /// the MAC check fires first, so we throw `.wrongPassword` rather than
    /// silently returning random-looking 32 bytes.
    func testWrongPasswordRejected() throws {
        let json = try encryptFixture()
        XCTAssertThrowsError(try BeeKeystore.decrypt(json, password: "wrong")) { error in
            XCTAssertEqual(error as? BeeKeystore.Error, .wrongPassword)
        }
    }

    /// Salt and IV must come from CSPRNG on every encrypt — a regression
    /// that pinned either to a constant would defeat the point of both.
    /// We pin the UUID so the random-UUID-by-default doesn't paper over a
    /// salt or IV collapse, then assert each load-bearing random field
    /// differs across two calls.
    func testFreshRandomnessAcrossEncrypts() throws {
        let pinnedID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let a = try encryptFixture(id: pinnedID)
        let b = try encryptFixture(id: pinnedID)
        let aDict = try parseCrypto(a)
        let bDict = try parseCrypto(b)
        XCTAssertNotEqual(aDict.salt, bDict.salt, "salt must be fresh per encrypt")
        XCTAssertNotEqual(aDict.iv, bDict.iv, "iv must be fresh per encrypt")
        XCTAssertNotEqual(aDict.ciphertext, bDict.ciphertext, "ciphertext follows from fresh salt+iv")
    }

    // MARK: - V3 JSON shape

    func testKeystoreCarriesV3Fields() throws {
        let json = try encryptFixture()
        let dict = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: json) as? [String: Any]
        )
        XCTAssertEqual(dict["version"] as? Int, 3)
        XCTAssertNotNil(dict["id"] as? String)
        XCTAssertNotNil(dict["address"] as? String)

        let crypto = try XCTUnwrap(dict["crypto"] as? [String: Any])
        XCTAssertEqual(crypto["cipher"] as? String, "aes-128-ctr")
        XCTAssertEqual(crypto["kdf"] as? String, "scrypt")
        XCTAssertNotNil(crypto["ciphertext"] as? String)
        XCTAssertNotNil(crypto["mac"] as? String)

        let kdfparams = try XCTUnwrap(crypto["kdfparams"] as? [String: Any])
        XCTAssertEqual(kdfparams["n"] as? Int, BeeKeystore.scryptN)
        XCTAssertEqual(kdfparams["r"] as? Int, BeeKeystore.scryptR)
        XCTAssertEqual(kdfparams["p"] as? Int, BeeKeystore.scryptP)
        XCTAssertEqual(kdfparams["dklen"] as? Int, BeeKeystore.dkLen)
        XCTAssertNotNil(kdfparams["salt"] as? String)

        let cipherparams = try XCTUnwrap(crypto["cipherparams"] as? [String: Any])
        XCTAssertNotNil(cipherparams["iv"] as? String)
    }

    /// Tampering with one ciphertext byte must fail the MAC check — the MAC
    /// is the sole integrity gate before we hand decrypted bytes back to a
    /// caller, so this is the test that catches a future regression where
    /// somebody "optimises" by skipping the MAC verification.
    func testTamperedCiphertextRejected() throws {
        var json = try encryptFixture()
        // Flip a bit in the JSON's ciphertext field — find the first hex
        // char of "ciphertext":"..." and mutate it.
        let s = String(decoding: json, as: UTF8.self)
        let marker = "\"ciphertext\":\""
        guard let range = s.range(of: marker) else {
            return XCTFail("ciphertext field not found")
        }
        let mutateIndex = range.upperBound
        let originalChar = s[mutateIndex]
        let replacement: Character = originalChar == "0" ? "1" : "0"
        let mutated = s.replacingCharacters(in: mutateIndex..<s.index(after: mutateIndex), with: String(replacement))
        json = Data(mutated.utf8)

        XCTAssertThrowsError(try BeeKeystore.decrypt(json, password: fixturePassword)) { error in
            XCTAssertEqual(error as? BeeKeystore.Error, .wrongPassword)
        }
    }

    // MARK: - Helpers

    private struct CryptoFields {
        let salt: String
        let iv: String
        let ciphertext: String
    }

    private func parseCrypto(_ json: Data) throws -> CryptoFields {
        let dict = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: json) as? [String: Any]
        )
        let crypto = try XCTUnwrap(dict["crypto"] as? [String: Any])
        let kdfparams = try XCTUnwrap(crypto["kdfparams"] as? [String: Any])
        let cipherparams = try XCTUnwrap(crypto["cipherparams"] as? [String: Any])
        return CryptoFields(
            salt: try XCTUnwrap(kdfparams["salt"] as? String),
            iv: try XCTUnwrap(cipherparams["iv"] as? String),
            ciphertext: try XCTUnwrap(crypto["ciphertext"] as? String)
        )
    }
}
