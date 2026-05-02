import XCTest
@testable import Freedom

/// Golden-vector tests proving the iOS Ed25519 keypair derivation
/// produces the exact same private + public keys desktop Freedom does
/// for the same BIP-39 seed. See docs/ipfs-identity-golden-vectors.md.
final class IpfsIdentityKeyTests: XCTestCase {
    /// 12-word `abandon abandon … about` BIP-39 seed.
    private let abandon12Seed = Data(hex: "0x5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4")!

    /// 24-word `abandon abandon … art` BIP-39 seed.
    private let abandon24Seed = Data(hex: "0x408b285c123836004f4b8842c89324c1f01382450c0d439af345ba7fc49acf705489c6fc77dbd4e3dc1dd8cc6bc9f043db8ada1e243c4a0eafb290d399480840")!

    func testAbandon12DerivesGoldenKeypair() throws {
        let key = try IpfsIdentityKey.derive(fromSeed: abandon12Seed)
        XCTAssertEqual(key.privateKey.web3.hexString,
                       "0x6d7c32198dff963096b93296acb383c9b4f2bd85a4e52c123bfee1e5cd00c749")
        XCTAssertEqual(key.publicKey.web3.hexString,
                       "0x91237ad5959a25e025487deebe7bbae444e5ac2dfcd6fd10442d43dd87ef5647")
    }

    func testAbandon24DerivesGoldenKeypair() throws {
        let key = try IpfsIdentityKey.derive(fromSeed: abandon24Seed)
        XCTAssertEqual(key.privateKey.web3.hexString,
                       "0x4212f8cf43eaa7070644e7b50a7e0d6ad7d02d8318890cb38d39935f66ba721a")
        XCTAssertEqual(key.publicKey.web3.hexString,
                       "0xf7120786aaf4255b760002c2051de31306dc4f73bca521fa842df307908c0f13")
    }

    func testDerivationIsDeterministic() throws {
        let a = try IpfsIdentityKey.derive(fromSeed: abandon12Seed)
        let b = try IpfsIdentityKey.derive(fromSeed: abandon12Seed)
        XCTAssertEqual(a, b)
    }

    func testDifferentSeedsProduceDifferentKeys() throws {
        let a = try IpfsIdentityKey.derive(fromSeed: abandon12Seed)
        let b = try IpfsIdentityKey.derive(fromSeed: abandon24Seed)
        XCTAssertNotEqual(a.privateKey, b.privateKey)
        XCTAssertNotEqual(a.publicKey, b.publicKey)
    }
}
