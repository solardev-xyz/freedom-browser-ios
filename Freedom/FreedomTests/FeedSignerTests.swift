import XCTest
import web3
@testable import Freedom

/// Pins iOS feed-signing at the recovery level — see `FeedSigner` for
/// why byte-equality isn't the right contract.
final class FeedSignerTests: XCTestCase {
    /// Test key kept stable across WP6 fixtures (also used by
    /// `SwarmSOCTests`'s SOC-address vectors). NOT a real key.
    private let testPrivateKey = Data(hex: String(repeating: "11", count: 32))!
    private let expectedOwnerHex = "19e7e376e7c213b7e7e7e46cc70a5dd086daff2a"

    func testOwnerAddressBytesMatchesBeeJSDerivation() throws {
        let owner = try FeedSigner.ownerAddressBytes(privateKey: testPrivateKey)
        XCTAssertEqual(owner.hexString, expectedOwnerHex)
    }

    func testSignatureRecoversToExpectedOwner() throws {
        let sig = try FeedSigner.sign(
            digest: capturedSocInnerHash, privateKey: testPrivateKey
        )
        let recovered = try KeyUtil.recoverPublicKey(
            message: signedDigest(of: capturedSocInnerHash), signature: sig
        )
        XCTAssertEqual(recovered.lowercased(), "0x" + expectedOwnerHex)
    }

    /// Bee-js's signature over the same message has *different bytes*
    /// (different deterministic-k nonce) but recovers to the same key.
    /// Pinning interop in this direction proves iOS will accept any
    /// signature bee-js can produce, not just iOS's own output.
    func testRecoversBeeJSCapturedSignatureToSameOwner() throws {
        let beeJSSignature = Data(hex:
            "77f7886e415f682f302edf81e03bbd1378fe324aeae72f04222e62fc20dd8479" +
            "6e9b37e9c34f3cf2274873d9c6b97de485c055c39de62ac1035f5aa3736f1441" +
            "1b")!
        let recovered = try KeyUtil.recoverPublicKey(
            message: signedDigest(of: capturedSocInnerHash),
            signature: beeJSSignature
        )
        XCTAssertEqual(recovered.lowercased(), "0x" + expectedOwnerHex)
    }

    /// RFC6979 deterministic nonce — same input must produce the same
    /// signature byte-for-byte across calls. Anything else means the
    /// secp256k1 SwiftPM dep flipped to a randomized k.
    func testSigningIsDeterministic() throws {
        let digest = Data(repeating: 0x42, count: 32)
        let sigA = try FeedSigner.sign(digest: digest, privateKey: testPrivateKey)
        let sigB = try FeedSigner.sign(digest: digest, privateKey: testPrivateKey)
        XCTAssertEqual(sigA, sigB)
    }

    func testDifferentDigestsProduceDifferentSignatures() throws {
        let sigA = try FeedSigner.sign(
            digest: Data(repeating: 0x01, count: 32), privateKey: testPrivateKey
        )
        let sigB = try FeedSigner.sign(
            digest: Data(repeating: 0x02, count: 32), privateKey: testPrivateKey
        )
        XCTAssertNotEqual(sigA, sigB)
    }

    // MARK: - Fixtures

    /// `keccak256(identifier || cacAddress)` for the (identifier,
    /// cacAddress) pair pinned in `SwarmSOCTests` — the inner hash bee
    /// computes before applying the EIP-191 prefix.
    private var capturedSocInnerHash: Data {
        let identifier = Data(hex:
            "ad1043721a8277e6f91f5ce59ee34dfb15ed1439db7f9ec2886731657ef9a74c")!
        let cacAddress = Data(hex:
            "fe60ba40b87599ddfb9e8947c1c872a4a1a5b56f7d1b80f0a646005b38db52a5")!
        return SwarmSOC.signingMessage(
            identifier: identifier, cacAddress: cacAddress
        ).web3.keccak256
    }

    /// What ECDSA actually signs:
    /// `keccak256("\x19Ethereum Signed Message:\n32" || innerHash)`.
    /// `KeyUtil.recoverPublicKey` takes that 32-byte digest directly.
    private func signedDigest(of innerHash: Data) -> Data {
        let prefix = "\u{19}Ethereum Signed Message:\n32".data(using: .ascii)!
        return (prefix + innerHash).web3.keccak256
    }
}
