import XCTest
@testable import Freedom

/// Golden-vector tests for the libp2p PrivKey protobuf and PeerID
/// encoders. Both are byte-stable functions of the input keypair, so a
/// single hard-coded expected value per mnemonic is enough — any
/// regression flips the assertion. See docs/ipfs-identity-golden-vectors.md.
final class IpfsIdentityFormatTests: XCTestCase {

    // MARK: - Golden inputs (Ed25519 keypairs at IPFS path)

    private let abandon12Priv = Data(hex: "0x6d7c32198dff963096b93296acb383c9b4f2bd85a4e52c123bfee1e5cd00c749")!
    private let abandon12Pub  = Data(hex: "0x91237ad5959a25e025487deebe7bbae444e5ac2dfcd6fd10442d43dd87ef5647")!

    private let abandon24Priv = Data(hex: "0x4212f8cf43eaa7070644e7b50a7e0d6ad7d02d8318890cb38d39935f66ba721a")!
    private let abandon24Pub  = Data(hex: "0xf7120786aaf4255b760002c2051de31306dc4f73bca521fa842df307908c0f13")!

    // MARK: - libp2p PrivKey base64

    func testAbandon12_Libp2pPrivKeyBase64() {
        let encoded = IpfsIdentityFormat.libp2pPrivKeyBase64(
            privateKey: abandon12Priv, publicKey: abandon12Pub
        )
        XCTAssertEqual(
            encoded,
            "CAESQG18MhmN/5Ywlrkylqyzg8m08r2FpOUsEjv+4eXNAMdJkSN61ZWaJeAlSH3uvnu65ETlrC381v0QRC1D3YfvVkc="
        )
    }

    func testAbandon24_Libp2pPrivKeyBase64() {
        let encoded = IpfsIdentityFormat.libp2pPrivKeyBase64(
            privateKey: abandon24Priv, publicKey: abandon24Pub
        )
        XCTAssertEqual(
            encoded,
            "CAESQEIS+M9D6qcHBkTntQp+DWrX0C2DGIkMs405k19munIa9xIHhqr0JVt2AALCBR3jEwbcT3O8pSH6hC3zB5CMDxM="
        )
    }

    func testLibp2pPrivKeyShape() {
        // Decode and structurally check: 4-byte protobuf header (08 01 12 40)
        // followed by 32-byte priv ‖ 32-byte pub.
        let encoded = IpfsIdentityFormat.libp2pPrivKeyBase64(
            privateKey: abandon12Priv, publicKey: abandon12Pub
        )
        let decoded = Data(base64Encoded: encoded)!
        XCTAssertEqual(decoded.count, 68)
        XCTAssertEqual(decoded[0..<4], Data([0x08, 0x01, 0x12, 0x40]))
        XCTAssertEqual(decoded[4..<36], abandon12Priv)
        XCTAssertEqual(decoded[36..<68], abandon12Pub)
    }

    // MARK: - PeerID

    func testAbandon12_PeerID() {
        let peerID = IpfsIdentityFormat.peerID(publicKey: abandon12Pub)
        XCTAssertEqual(peerID, "12D3KooWKavfSLKnBEoUdrcsZKHE2tCWxrPkND6psrNRyL8DgtYW")
    }

    func testAbandon24_PeerID() {
        let peerID = IpfsIdentityFormat.peerID(publicKey: abandon24Pub)
        XCTAssertEqual(peerID, "12D3KooWSSppFRXRiW23YYh5zC8ZqSR2C3UgL2oJqhM5PjsAmxPk")
    }

    func testPeerIDStartsWith12D3KooW() {
        // All Ed25519 PeerIDs encoded via identity-multihash + base58
        // share this prefix; if the prefix changes we've broken the
        // multihash header (0x00 0x24) or the protobuf wrapping.
        let peerID = IpfsIdentityFormat.peerID(publicKey: abandon12Pub)
        XCTAssertTrue(peerID.hasPrefix("12D3KooW"))
    }
}
