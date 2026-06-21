import SwarmKit
import XCTest

/// Locks the contract behind `SwarmNode.writeInjectedIdentity` — the
/// seeded `identity.json` Ant reads at `ant_init`. The **zero overlay
/// nonce** is load-bearing: it's what makes the overlay address
/// byte-identical to desktop `antd`'s `keys/swarm.key` injection branch
/// (which also uses a zero nonce) for the same wallet key. Regressing it
/// would silently give mobile a different overlay than desktop.
final class SwarmIdentitySeedTests: XCTestCase {

    func testSeedsSigningKeyAndZeroOverlayNonce() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swarm-id-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 32-byte key with a recognisable pattern (0x00…1f).
        let key = Data((0..<32).map { UInt8($0) })
        try SwarmNode.writeInjectedIdentity(signingKey: key, dataDir: dir)

        let url = dir.appendingPathComponent("identity.json")
        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as? [String: Any]

        XCTAssertEqual(
            json?["signing_key"] as? String,
            "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
            "signing_key must be lowercase hex of the 32 raw bytes"
        )
        XCTAssertEqual(
            json?["overlay_nonce"] as? String,
            String(repeating: "0", count: 64),
            "overlay_nonce must be 32 zero bytes to match desktop's overlay"
        )
        XCTAssertNil(
            json?["libp2p_keypair"],
            "libp2p_keypair must be omitted so Ant derives it from the signing key"
        )
    }

    func testRejectsWrongKeyLength() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swarm-id-bad-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(
            try SwarmNode.writeInjectedIdentity(signingKey: Data(count: 31), dataDir: dir)
        )
    }
}
