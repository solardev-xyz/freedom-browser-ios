import XCTest
@testable import Freedom

final class MnemonicTests: XCTestCase {
    /// BIP-39 English vectors from trezor/python-mnemonic. `seedHex` is
    /// derived with passphrase `"TREZOR"` — the convention of that suite.
    private struct Vector {
        let entropyHex: String
        let mnemonic: String
        let seedHex: String
    }

    private let vectors: [Vector] = [
        Vector(
            entropyHex: "00000000000000000000000000000000",
            mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
            seedHex: "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04"
        ),
        Vector(
            entropyHex: "80808080808080808080808080808080",
            mnemonic: "letter advice cage absurd amount doctor acoustic avoid letter advice cage above",
            seedHex: "d71de856f81a8acc65e6fc851a38d4d7ec216fd0796d0a6827a3ad6ed5511a30fa280f12eb2e47ed2ac03b5c462a0358d18d69fe4f985ec81778c1b370b652a8"
        ),
        Vector(
            entropyHex: "ffffffffffffffffffffffffffffffff",
            mnemonic: "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong",
            seedHex: "ac27495480225222079d7be181583751e86f571027b0497b5b5d11218e0a8a13332572917f0f8e5a589620c6f15b11c61dee327651a14c34e18231052e48c069"
        ),
        Vector(
            entropyHex: "9e885d952ad362caeb4efe34a8e91bd2",
            mnemonic: "ozone drill grab fiber curtain grace pudding thank cruise elder eight picnic",
            seedHex: "274ddc525802f7c828d8ef7ddbcdc5304e87ac3535913611fbbfa986d0c9e5476c91689f9c8a54fd55bd38606aa6a8595ad213d4c9c9f9aca3fb217069a41028"
        ),
        Vector(
            entropyHex: "000000000000000000000000000000000000000000000000",
            mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon agent",
            seedHex: "035895f2f481b1b0f01fcf8c289c794660b289981a78f8106447707fdd9666ca06da5a9a565181599b79f53b844d8a71dd9f439c52a3d7b3e8a79c906ac845fa"
        ),
        Vector(
            entropyHex: "0000000000000000000000000000000000000000000000000000000000000000",
            mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art",
            seedHex: "bda85446c68413707090a52022edd26a1c9462295029f2e60cd7c4f2bbd3097170af7a4d73245cafa9c3cca8d561a7c3de6f5d4a10be8ed2a5e608d68f92fcc8"
        ),
        Vector(
            entropyHex: "f585c11aec520db57dd353c69554b21a89b20fb0650966fa0a9d6f74fd989d8f",
            mnemonic: "void come effort suffer camp survey warrior heavy shoot primary clutch crush open amazing screen patrol group space point ten exist slush involve unfold",
            seedHex: "01f5bced59dec48e362f2c45b5de68b9fd6c92c6634f44d6d40aab69056506f0e35524a518034ddc1192e1dacd32c1ed3eaa3c3b131c88ed8e7e54c49a5d0998"
        ),
    ]

    func testEntropyToMnemonic() throws {
        for v in vectors {
            let entropy = Data(hex: "0x\(v.entropyHex)")!
            let m = try Mnemonic(entropy: entropy)
            XCTAssertEqual(m.words.joined(separator: " "), v.mnemonic, "entropy \(v.entropyHex)")
        }
    }

    func testMnemonicToSeed() throws {
        for v in vectors {
            let m = try Mnemonic(phrase: v.mnemonic)
            XCTAssertEqual(
                m.seed(passphrase: "TREZOR").hexString,
                v.seedHex,
                "phrase starting \(v.mnemonic.prefix(20))…"
            )
        }
    }

    func testMnemonicRoundTrip() throws {
        for v in vectors {
            let fromEntropy = try Mnemonic(entropy: Data(hex: "0x\(v.entropyHex)")!)
            let fromPhrase = try Mnemonic(phrase: v.mnemonic)
            XCTAssertEqual(fromEntropy, fromPhrase)
        }
    }

    func testFreshMnemonicIs24Words() {
        let m = Mnemonic()
        XCTAssertEqual(m.words.count, 24)
        // Two consecutive calls must differ (CSPRNG contract).
        XCTAssertNotEqual(Mnemonic().words, Mnemonic().words)
    }

    func testFreshMnemonicChecksumsAsValid() throws {
        let m = Mnemonic()
        XCTAssertNoThrow(try Mnemonic(phrase: m.words.joined(separator: " ")))
    }

    func testInvalidChecksumRejected() {
        // Valid 12 words except the last is swapped — flips the 4-bit checksum.
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon wrong"
        XCTAssertThrowsError(try Mnemonic(phrase: phrase)) { error in
            XCTAssertEqual(error as? Mnemonic.Error, .invalidChecksum)
        }
    }

    func testUnknownWordRejected() {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon notaword"
        XCTAssertThrowsError(try Mnemonic(phrase: phrase)) { error in
            XCTAssertEqual(error as? Mnemonic.Error, .unknownWord("notaword"))
        }
    }

    func testInvalidWordCountRejected() {
        // 13 words — no BIP-39 strength has this length.
        let phrase = Array(repeating: "abandon", count: 13).joined(separator: " ")
        XCTAssertThrowsError(try Mnemonic(phrase: phrase)) { error in
            XCTAssertEqual(error as? Mnemonic.Error, .invalidWordCount)
        }
    }

    func testEmptyPassphraseSeedDiffersFromTrezorSeed() throws {
        // Sanity check that our seed() actually varies on passphrase — not
        // just always returning the TREZOR seed. (Trezor vectors use "TREZOR";
        // desktop wallets use "".)
        let m = try Mnemonic(phrase: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
        XCTAssertNotEqual(m.seed().hexString, m.seed(passphrase: "TREZOR").hexString)
    }

    func testWordlistIs2048Canonical() {
        XCTAssertEqual(BIP39English.words.count, 2048)
        XCTAssertEqual(BIP39English.words.first, "abandon")
        XCTAssertEqual(BIP39English.words.last, "zoo")
    }
}
