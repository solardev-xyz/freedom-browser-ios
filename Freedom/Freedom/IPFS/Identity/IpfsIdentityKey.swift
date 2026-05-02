import CryptoKit
import Foundation

/// IPFS identity keypair — a 32-byte Ed25519 private/public pair derived
/// deterministically from the user's BIP-39 mnemonic seed at the
/// canonical Freedom IPFS path.
///
/// Same path and derivation as desktop Freedom (`identity/derivation.js`,
/// `PATHS.IPFS`), so a user with the same seed phrase on both platforms
/// gets the same PeerID.
struct IpfsIdentityKey: Equatable {
    /// SLIP-0010 Ed25519 path. Custom unregistered coin type 73405; all
    /// segments hardened (required for Ed25519). Must stay aligned with
    /// desktop's `PATHS.IPFS`.
    static let path = "m/44'/73405'/0'/0'/0'"

    /// 32-byte Ed25519 private key (seed for Curve25519 keygen).
    let privateKey: Data
    /// 32-byte Ed25519 public key.
    let publicKey: Data

    /// Derive the IPFS identity keypair from a BIP-39 master seed (the
    /// 64-byte PBKDF2 output of mnemonic + passphrase).
    static func derive(fromSeed seed: Data) throws -> IpfsIdentityKey {
        let derived = try SLIP10Ed25519.derive(seed: seed, path: path)
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: derived.key)
        return IpfsIdentityKey(
            privateKey: derived.key,
            publicKey: signingKey.publicKey.rawRepresentation
        )
    }
}
