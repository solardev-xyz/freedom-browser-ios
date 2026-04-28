import Foundation
import web3

/// EIP-191 signing seam between `SwarmSOC`'s 64-byte signing messages
/// and the vault's HD-derived keys. Bee verifies SOC ownership by
/// recovering the signer's public key from the signature, so iOS only
/// needs to produce *recoverable-equivalent* signatures — bee-js's and
/// libsecp256k1's deterministic-k nonces differ, so the byte-strings
/// won't match, but both recover to the same address. Tests pin
/// recovery, not bytes.
///
/// Takes raw 32-byte private key (rather than `Vault` + `HDKey.Path`)
/// so unit tests pin a known key without fabricating a BIP-32
/// derivation. The bridge handler that wires this up resolves the
/// path via `vault.signingKey(at:).privateKey`.
enum FeedSigner {
    enum Error: Swift.Error, Equatable {
        case malformedSignature
    }

    /// EIP-191 personal_sign over a 32-byte digest. Returns the 65-byte
    /// signature (`r || s || v` with `v ∈ {27, 28}`). Callers MUST
    /// pre-hash the SOC signing message — passing raw 64 bytes would
    /// have web3.swift prefix it as `\n64`, producing a signature bee
    /// rejects.
    static func sign(digest: Data, privateKey: Data) throws -> Data {
        precondition(digest.count == 32, "digest must be 32 bytes")
        precondition(privateKey.count == 32, "privateKey must be 32 bytes")
        let account = try EthereumAccount(
            keyStorage: HDKeyStorage(privateKey: privateKey)
        )
        let hex = try account.signMessage(message: digest)
        guard let bytes = Data(hex: hex), bytes.count == 65 else {
            throw Error.malformedSignature
        }
        return bytes
    }

    /// 20-byte raw ethereum address — feeds into
    /// `SwarmSOC.socAddress(identifier:ownerAddress:)` and the URL path
    /// of `POST /soc/{owner}/{id}`.
    static func ownerAddressBytes(privateKey: Data) throws -> Data {
        precondition(privateKey.count == 32, "privateKey must be 32 bytes")
        let account = try EthereumAccount(
            keyStorage: HDKeyStorage(privateKey: privateKey)
        )
        guard let bytes = account.address.asData(), bytes.count == 20 else {
            throw Error.malformedSignature
        }
        return bytes
    }
}
