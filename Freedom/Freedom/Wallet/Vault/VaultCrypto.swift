import CryptoKit
import Foundation
import Security

/// On-disk encryption for the wallet seed. Three tiers — the caller picks a
/// preferred tier at construction, and the store path falls back to
/// `.deviceBound` whenever the preferred tier can't be realised on the
/// current device (no passcode enrolled, Secure Enclave unavailable, etc).
///
///   - **cloudSynced** (v1 default): DEK and blob stored in iCloud-synced
///     Keychain (no `SecAccessControl` — iCloud Keychain refuses items
///     that carry one). The biometric/passcode gate is applied at the app
///     layer via `LAContext.evaluatePolicy` on the unlock path, not at
///     the Keychain layer. Backed up via iCloud Keychain so device loss
///     doesn't strand funds. Trade: slightly weaker than `.protected`
///     (Apple-ID compromise becomes a path; a jailbroken device could
///     bypass the app-level gate) for dramatically better UX.
///
///   - **protected**: Secure Enclave P-256 key wraps a random 32-byte DEK
///     via ECIES; SE's `.userPresence` ACL gates every unwrap. Keys never
///     leave the chip, so the vault is strictly this-device-only. Kept
///     wired up for a future "advanced security" opt-in — not selected by
///     default in v1.
///
///   - **deviceBound**: raw DEK in Keychain (`.whenUnlockedThisDeviceOnly`,
///     no ACL). The fallback when the preferred tier can't be created.
///     Still encrypted at rest by system hardware keys; no user-presence
///     gate because there's nothing to gate on.
///
/// Which tier was chosen is recorded alongside the blob and honored on load.
final class VaultCrypto {
    enum Error: Swift.Error {
        case noVault
        case corrupted
        case cryptoFailed
        case keychain(OSStatus)
    }

    private let blob: KeychainItem
    private let dek: KeychainItem
    private let level: KeychainItem
    private let seKeyTag: Data
    private let preferred: VaultSecurityLevel
    private let prompter: BiometricPrompter

    init(
        service: String = "com.freedom.wallet",
        preferred: VaultSecurityLevel = .cloudSynced,
        prompter: BiometricPrompter = LocalAuthenticationPrompter()
    ) {
        self.blob = KeychainItem(account: "blob", service: service)
        self.dek = KeychainItem(account: "dek", service: service)
        self.level = KeychainItem(account: "level", service: service)
        self.seKeyTag = Data("\(service).se".utf8)
        self.preferred = preferred
        self.prompter = prompter
    }

    var existingLevel: VaultSecurityLevel? {
        guard let data = try? level.read(),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return VaultSecurityLevel(rawValue: s)
    }

    func store(mnemonic: Mnemonic) throws -> VaultSecurityLevel {
        guard let dekBytes = Data.secureRandom(count: 32) else { throw Error.cryptoFailed }

        let resolved = try writeDek(dekBytes, preferred: preferred)
        let blobProtection: KeychainItem.Protection =
            (resolved == .cloudSynced) ? .cloudSynced : .deviceOnly
        try blob.write(try sealBlob(mnemonic: mnemonic, dek: dekBytes), protection: blobProtection)
        try level.write(Data(resolved.rawValue.utf8), protection: blobProtection)
        return resolved
    }

    func load() async throws -> Mnemonic {
        guard let resolvedLevel = existingLevel else { throw Error.noVault }
        // App-level biometric gate — see §5.2 on why this can't live on
        // the Keychain item itself for the cloudSynced tier. Throws if
        // the user cancels or the device's passcode has been removed
        // since create-time.
        if resolvedLevel == .cloudSynced {
            try await prompter.prompt(reason: "Unlock your wallet")
        }
        guard let storedDek = try dek.read(), let sealed = try blob.read() else {
            throw Error.corrupted
        }
        let dekBytes: Data
        switch resolvedLevel {
        case .protected:
            // SE decrypt triggers the system prompt at the kernel level.
            dekBytes = try decrypt(wrappedDek: storedDek, with: try fetchSEPrivateKey())
        case .cloudSynced, .deviceBound:
            dekBytes = storedDek
        }
        return try openBlob(sealed, dek: dekBytes)
    }

    func wipe() throws {
        try blob.delete()
        try dek.delete()
        try level.delete()
        _ = try? deleteSEKey()
    }

    // MARK: - DEK writing per tier

    private func writeDek(_ dekBytes: Data, preferred: VaultSecurityLevel) throws -> VaultSecurityLevel {
        switch preferred {
        case .cloudSynced:
            // Can only land on this tier if the device has a usable
            // biometric or passcode — that's what the prompter evaluates
            // at unlock time. Without one, there's nothing to gate on,
            // so we'd effectively be storing a plaintext DEK in iCloud.
            // Fall back to .deviceBound in that case.
            if prompter.canPrompt() {
                try dek.write(dekBytes, protection: .cloudSynced)
                return .cloudSynced
            }
            try dek.write(dekBytes, protection: .deviceOnly)
            return .deviceBound
        case .protected:
            if let sePublic = try createOrFetchSEPublicKey() {
                try dek.write(try encrypt(dek: dekBytes, with: sePublic), protection: .deviceOnly)
                return .protected
            }
            try dek.write(dekBytes, protection: .deviceOnly)
            return .deviceBound
        case .deviceBound:
            try dek.write(dekBytes, protection: .deviceOnly)
            return .deviceBound
        }
    }

    // MARK: - Secure Enclave (`.protected` tier)

    private func createOrFetchSEPublicKey() throws -> SecKey? {
        if let existing = try? fetchSEPrivateKey() {
            return SecKeyCopyPublicKey(existing)
        }
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .userPresence],
            &accessError
        ) else { return nil }

        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: seKeyTag,
                kSecAttrAccessControl as String: access,
            ],
        ]
        // nil (not throw) on SE unavailability is intentional: the caller
        // falls back to .deviceBound. Triggered by no passcode, simulator
        // quirks, or legacy hardware.
        var createError: Unmanaged<CFError>?
        return SecKeyCreateRandomKey(attrs as CFDictionary, &createError)
            .flatMap { SecKeyCopyPublicKey($0) }
    }

    private func fetchSEPrivateKey() throws -> SecKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecAttrApplicationTag as String: seKeyTag,
            kSecReturnRef as String: true,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let ref = out else {
            throw Error.keychain(status)
        }
        return ref as! SecKey
    }

    private func deleteSEKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: seKeyTag,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Error.keychain(status)
        }
    }

    private func encrypt(dek: Data, with publicKey: SecKey) throws -> Data {
        guard let encrypted = SecKeyCreateEncryptedData(
            publicKey,
            .eciesEncryptionCofactorVariableIVX963SHA256AESGCM,
            dek as CFData,
            nil
        ) else { throw Error.cryptoFailed }
        return encrypted as Data
    }

    private func decrypt(wrappedDek: Data, with privateKey: SecKey) throws -> Data {
        guard let decrypted = SecKeyCreateDecryptedData(
            privateKey,
            .eciesEncryptionCofactorVariableIVX963SHA256AESGCM,
            wrappedDek as CFData,
            nil
        ) else { throw Error.cryptoFailed }
        return decrypted as Data
    }

    // MARK: - AES-GCM blob

    private struct Blob: Codable {
        let version: Int
        let mnemonic: String
    }

    private func sealBlob(mnemonic: Mnemonic, dek: Data) throws -> Data {
        let blob = Blob(version: 1, mnemonic: mnemonic.words.joined(separator: " "))
        let json = try JSONEncoder().encode(blob)
        let sealed = try AES.GCM.seal(json, using: SymmetricKey(data: dek))
        guard let combined = sealed.combined else { throw Error.cryptoFailed }
        return combined
    }

    private func openBlob(_ data: Data, dek: Data) throws -> Mnemonic {
        let sealed = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(sealed, using: SymmetricKey(data: dek))
        let blob = try JSONDecoder().decode(Blob.self, from: plaintext)
        return try Mnemonic(phrase: blob.mnemonic)
    }
}
