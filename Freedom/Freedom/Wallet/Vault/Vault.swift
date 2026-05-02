import Foundation
import Observation
import web3

/// Stored alongside the vault blob and read back verbatim. Pinned raw values
/// keep the on-disk format decoupled from Swift case names.
enum VaultSecurityLevel: String {
    case cloudSynced = "cloud-synced"
    case protected = "protected"
    case deviceBound = "device-bound"
}

@MainActor
@Observable
final class Vault {
    enum State: Equatable {
        case empty
        case locked
        case unlocked
    }

    enum Error: Swift.Error {
        case alreadyExists
        case noVault
        case notUnlocked
    }

    private(set) var state: State
    private(set) var securityLevel: VaultSecurityLevel?

    @ObservationIgnored private var seed: Data?
    @ObservationIgnored private let crypto: VaultCrypto

    init(crypto: VaultCrypto = VaultCrypto()) {
        self.crypto = crypto
        if let level = crypto.existingLevel {
            self.state = .locked
            self.securityLevel = level
        } else {
            self.state = .empty
            self.securityLevel = nil
        }
    }

    func create(mnemonic: Mnemonic) async throws {
        guard state == .empty else { throw Error.alreadyExists }
        let (derivedSeed, level) = try await Task.detached(priority: .userInitiated) { [crypto] in
            let level = try crypto.store(mnemonic: mnemonic)
            return (mnemonic.seed(), level)
        }.value
        self.seed = derivedSeed
        self.securityLevel = level
        self.state = .unlocked
    }

    func unlock() async throws {
        guard state == .locked else { throw Error.noVault }
        let derivedSeed = try await Task.detached(priority: .userInitiated) { [crypto] in
            try await crypto.load().seed()
        }.value
        self.seed = derivedSeed
        self.state = .unlocked
    }

    func lock() {
        zero(&seed)
        if state != .empty { state = .locked }
    }

    /// Derive the key at `path` from the current unlocked seed. The returned
    /// `HDKey` is the caller's to use and drop — the Data inside it is not
    /// zeroed on drop (Swift's Data doesn't guarantee that). Keep it scoped
    /// to a single signing operation.
    func signingKey(at path: HDKey.Path) throws -> HDKey {
        guard let seed else { throw Error.notUnlocked }
        return try HDKey(seed: seed).derive(path)
    }

    /// Sugar over `signingKey(at:)` for callers that want to hand the
    /// derived key straight to Argent's `EthereumAccount` for signing.
    /// Same one-shot lifetime contract.
    func signingAccount(at path: HDKey.Path = .mainUser) throws -> EthereumAccount {
        let hdKey = try signingKey(at: path)
        return try EthereumAccount(keyStorage: HDKeyStorage(privateKey: hdKey.privateKey))
    }

    /// The 64-byte BIP-39 master seed (PBKDF2 output of mnemonic +
    /// passphrase). Used by SLIP-0010 derivations — currently the IPFS
    /// Ed25519 identity at `m/44'/73405'/0'/0'/0'` — which need the
    /// pre-BIP-32 seed material. Same one-shot lifetime contract as
    /// `signingKey(at:)`: the returned Data is not zeroed on drop;
    /// keep it scoped to a single derivation.
    func bip39Seed() throws -> Data {
        guard let seed else { throw Error.notUnlocked }
        return seed
    }

    /// Re-reads the mnemonic from Keychain storage, triggering a fresh
    /// biometric prompt on the cloudSynced tier. Used for "Show recovery
    /// phrase" — we deliberately don't cache the words on the Vault, so
    /// displaying them always costs an explicit re-auth.
    func revealMnemonic() async throws -> Mnemonic {
        try await Task.detached(priority: .userInitiated) { [crypto] in
            try await crypto.load()
        }.value
    }

    func wipe() async throws {
        try await Task.detached(priority: .userInitiated) { [crypto] in
            try crypto.wipe()
        }.value
        zero(&seed)
        state = .empty
        securityLevel = nil
    }

    /// `memset_s` isn't elided by the optimiser the way plain `memset` can
    /// be. Only the buffer *this* Data reference owns is zeroed — any copies
    /// elsewhere were never tracked. `Data` is a value type, and we never
    /// intentionally hand it out, but the guarantee is best-effort.
    private func zero(_ buf: inout Data?) {
        buf?.withUnsafeMutableBytes { ptr in
            if let base = ptr.baseAddress, ptr.count > 0 {
                memset_s(base, ptr.count, 0, ptr.count)
            }
        }
        buf = nil
    }
}
