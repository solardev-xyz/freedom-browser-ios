import Foundation

/// libp2p key-format converters for kubo's `Identity` config block.
///
/// Mirrors desktop Freedom (`identity/formats.js:createIpfsIdentity`)
/// byte-for-byte so an iOS-derived identity is indistinguishable from
/// a desktop-derived one for the same mnemonic.
enum IpfsIdentityFormat {
    /// Encode an Ed25519 keypair as the base64 string kubo expects in
    /// `<dataDir>/config` `Identity.PrivKey`.
    ///
    /// libp2p PrivateKey protobuf:
    ///   field 1 (Type=Ed25519=1): tag 0x08, varint value 0x01
    ///   field 2 (Data, 64 bytes): tag 0x12, length 0x40, then priv ‖ pub
    /// Total 68 bytes. Base64-encoded for JSON config use.
    static func libp2pPrivKeyBase64(privateKey: Data, publicKey: Data) -> String {
        precondition(privateKey.count == 32, "Ed25519 private key must be 32 bytes")
        precondition(publicKey.count == 32, "Ed25519 public key must be 32 bytes")
        var protobuf = Data(capacity: 68)
        protobuf.append(0x08); protobuf.append(0x01)   // Type = Ed25519
        protobuf.append(0x12); protobuf.append(0x40)   // Data: 64 bytes follow
        protobuf.append(privateKey)
        protobuf.append(publicKey)
        return protobuf.base64EncodedString()
    }

    /// Compute the Base58 PeerID for an Ed25519 public key.
    ///
    /// Pipeline:
    ///   1. Wrap the pubkey in libp2p PublicKey protobuf:
    ///        field 1 (Type=1):           0x08 0x01
    ///        field 2 (Data, 32 bytes):   0x12 0x20 + pubkey  → 36 bytes
    ///   2. Apply identity multihash (no actual hashing):
    ///        0x00 (code "identity") + 0x24 (length 36) + protobuf  → 38 bytes
    ///   3. Base58 (Bitcoin alphabet) → "12D3KooW…" PeerID.
    ///
    /// Identity multihash is used for keys ≤ 42 bytes; Ed25519 pubkeys
    /// (32 bytes) always qualify. Same path desktop and kubo use.
    static func peerID(publicKey: Data) -> String {
        precondition(publicKey.count == 32, "Ed25519 public key must be 32 bytes")
        var pubProto = Data(capacity: 36)
        pubProto.append(0x08); pubProto.append(0x01)   // Type = Ed25519
        pubProto.append(0x12); pubProto.append(0x20)   // Data: 32 bytes follow
        pubProto.append(publicKey)
        var multihash = Data(capacity: 2 + pubProto.count)
        multihash.append(0x00)                         // identity multihash code
        multihash.append(UInt8(pubProto.count))        // 36
        multihash.append(pubProto)
        return Base58.encode(multihash)
    }
}
