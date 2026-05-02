import XCTest
@testable import Freedom

/// Two-source verification:
///  - Spec vectors from the SLIP-0010 reference document (authoritative).
///  - Golden vectors from desktop Freedom for the IPFS-specific path,
///    so iOS and desktop agree byte-for-byte for the same mnemonic.
final class SLIP10Ed25519Tests: XCTestCase {

    // MARK: - SLIP-0010 spec vectors (Test vector 1 for ed25519)
    // https://github.com/satoshilabs/slips/blob/master/slip-0010.md

    private let specSeed1 = Data(hex: "0x000102030405060708090a0b0c0d0e0f")!

    func testSpecVector1_Master() throws {
        let derived = try SLIP10Ed25519.derive(seed: specSeed1, path: "m")
        XCTAssertEqual(derived.key.web3.hexString,
                       "0x2b4be7f19ee27bbf30c667b642d5f4aa69fd169872f8fc3059c08ebae2eb19e7")
        XCTAssertEqual(derived.chainCode.web3.hexString,
                       "0x90046a93de5380a72b5e45010748567d5ea02bbf6522f979e05c0d8d8ca9fffb")
    }

    func testSpecVector1_DerivedM0H() throws {
        let derived = try SLIP10Ed25519.derive(seed: specSeed1, path: "m/0'")
        XCTAssertEqual(derived.key.web3.hexString,
                       "0x68e0fe46dfb67e368c75379acec591dad19df3cde26e63b93a8e704f1dade7a3")
        XCTAssertEqual(derived.chainCode.web3.hexString,
                       "0x8b59aa11380b624e81507a27fedda59fea6d0b779a778918a2fd3590e16e9c69")
    }

    func testSpecVector1_DerivedM0H1H2H2H1000000000H() throws {
        let derived = try SLIP10Ed25519.derive(seed: specSeed1, path: "m/0'/1'/2'/2'/1000000000'")
        XCTAssertEqual(derived.key.web3.hexString,
                       "0x8f94d394a8e8fd6b1bc2f3f49f5c47e385281d5c17e65324b0f62483e37e8793")
        XCTAssertEqual(derived.chainCode.web3.hexString,
                       "0x68789923a0cac2cd5a29172a475fe9e0fb14cd6adb5ad98a3fa70333e7afa230")
    }

    // MARK: - SLIP-0010 spec vectors (Test vector 2 for ed25519)

    private let specSeed2 = Data(hex: "0xfffcf9f6f3f0edeae7e4e1dedbd8d5d2cfccc9c6c3c0bdbab7b4b1aeaba8a5a29f9c999693908d8a8784817e7b7875726f6c696663605d5a5754514e4b484542")!

    func testSpecVector2_Master() throws {
        let derived = try SLIP10Ed25519.derive(seed: specSeed2, path: "m")
        XCTAssertEqual(derived.key.web3.hexString,
                       "0x171cb88b1b3c1db25add599712e36245d75bc65a1a5c9e18d76f9f2b1eab4012")
        XCTAssertEqual(derived.chainCode.web3.hexString,
                       "0xef70a74db9c3a5af931b5fe73ed8e1a53464133654fd55e7a66f8570b8e33c3b")
    }

    func testSpecVector2_DerivedM0H() throws {
        let derived = try SLIP10Ed25519.derive(seed: specSeed2, path: "m/0'")
        XCTAssertEqual(derived.key.web3.hexString,
                       "0x1559eb2bbec5790b0c65d8693e4d0875b1747f4970ae8b650486ed7470845635")
        XCTAssertEqual(derived.chainCode.web3.hexString,
                       "0x0b78a3226f915c082bf118f83618a618ab6dec793752624cbeb622acb562862d")
    }

    // MARK: - Desktop golden vectors (IPFS path)

    /// 12-word abandon mnemonic BIP-39 seed (PBKDF2 output, no passphrase).
    private let abandon12Seed = Data(hex: "0x5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4")!

    /// 24-word abandon mnemonic BIP-39 seed.
    private let abandon24Seed = Data(hex: "0x408b285c123836004f4b8842c89324c1f01382450c0d439af345ba7fc49acf705489c6fc77dbd4e3dc1dd8cc6bc9f043db8ada1e243c4a0eafb290d399480840")!

    func testGoldenVector_Abandon12_IPFSPath() throws {
        let derived = try SLIP10Ed25519.derive(seed: abandon12Seed, path: IpfsIdentityKey.path)
        XCTAssertEqual(derived.key.web3.hexString,
                       "0x6d7c32198dff963096b93296acb383c9b4f2bd85a4e52c123bfee1e5cd00c749")
    }

    func testGoldenVector_Abandon24_IPFSPath() throws {
        let derived = try SLIP10Ed25519.derive(seed: abandon24Seed, path: IpfsIdentityKey.path)
        XCTAssertEqual(derived.key.web3.hexString,
                       "0x4212f8cf43eaa7070644e7b50a7e0d6ad7d02d8318890cb38d39935f66ba721a")
    }

    // MARK: - Path parsing

    func testPathParsingRejectsNonHardenedSegment() {
        XCTAssertThrowsError(try SLIP10Ed25519.parsePath("m/44/60'/0'")) { error in
            guard case SLIP10Ed25519.Error.nonHardenedSegment = error else {
                return XCTFail("expected .nonHardenedSegment, got \(error)")
            }
        }
    }

    func testPathParsingRejectsBadFormat() {
        XCTAssertThrowsError(try SLIP10Ed25519.parsePath("44'/60'"))
        XCTAssertThrowsError(try SLIP10Ed25519.parsePath("m/"))
        XCTAssertThrowsError(try SLIP10Ed25519.parsePath("m/abc'"))
    }

    func testPathParsingRootMReturnsEmpty() throws {
        XCTAssertEqual(try SLIP10Ed25519.parsePath("m"), [])
    }

    func testPathParsingHardensCorrectly() throws {
        let indices = try SLIP10Ed25519.parsePath("m/44'/73405'/0'/0'/0'")
        let h: UInt32 = 0x80000000
        XCTAssertEqual(indices, [
            UInt32(44)    | h,
            UInt32(73405) | h,
            UInt32(0)     | h,
            UInt32(0)     | h,
            UInt32(0)     | h,
        ])
    }
}
