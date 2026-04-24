import Foundation
import web3

/// Wallet-side EIP-191 / EIP-712 signing. `vault.signingAccount(at:)` reads
/// a fresh `HDKey` per call so the private key never persists across signs.
@MainActor
enum MessageSigner {
    /// EIP-191 `personal_sign`. Returns 0x-prefixed hex of the 65-byte
    /// signature (r || s || v, with v ∈ {27, 28}).
    static func signPersonalMessage(_ data: Data, vault: Vault) throws -> String {
        try vault.signingAccount().signMessage(message: data)
    }

    /// EIP-712 `eth_signTypedData_v4`. Same return shape as personal_sign.
    static func signTypedData(_ typed: TypedData, vault: Vault) throws -> String {
        try vault.signingAccount().signMessage(message: typed)
    }
}
