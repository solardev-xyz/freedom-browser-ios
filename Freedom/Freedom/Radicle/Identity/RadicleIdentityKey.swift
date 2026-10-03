import CryptoKit
import Foundation

/// Radicle node identity — an Ed25519 keypair derived deterministically
/// from the user's BIP-39 seed at the canonical Freedom Radicle path.
/// Same path and derivation as desktop (`identity/derivation.js`,
/// `PATHS.RADICLE`), so a user with the same phrase on both platforms
/// gets the same DID.
struct RadicleIdentityKey: Equatable {
    /// SLIP-0010 Ed25519 path. Custom unregistered coin type 73404; all
    /// segments hardened (required for Ed25519). Must stay aligned with
    /// desktop's `PATHS.RADICLE`.
    static let path = "m/44'/73404'/0'/0'/0'"

    /// 32-byte Ed25519 secret seed (RFC 8032) — what libradicle's
    /// `start_with_key` takes.
    let privateKey: Data
    /// 32-byte Ed25519 public key.
    let publicKey: Data

    static func derive(fromSeed seed: Data) throws -> RadicleIdentityKey {
        let derived = try SLIP10Ed25519.derive(seed: seed, path: path)
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: derived.key)
        return RadicleIdentityKey(privateKey: derived.key, publicKey: signingKey.publicKey.rawRepresentation)
    }

    /// `did:key:z6Mk…`: multibase base58btc of the ed25519-pub multicodec
    /// (0xed, varint 0xed01) followed by the public key — what radicle
    /// reports as the node's DID.
    var did: String { Self.did(publicKey: publicKey) }

    static func did(publicKey: Data) -> String {
        "did:key:z" + Base58.encode(Data([0xed, 0x01]) + publicKey)
    }
}
