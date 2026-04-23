import CryptoKit
import Foundation
import Security

/// On-disk encryption for the wallet seed. Two tiers selected at store time:
///
///   - **protected**: a Secure Enclave P-256 key wraps a random 32-byte DEK
///     via ECIES; the DEK decrypts the vault blob on unlock. Every unlock
///     traverses the SE, which enforces the `.userPresence` ACL — biometric
///     or device passcode — at the kernel level.
///   - **deviceBound**: device has no passcode (or SE unavailable), so the
///     DEK is stored directly in Keychain with `.whenUnlockedThisDeviceOnly`.
///     Still encrypted at rest, still device-bound, but with no user-presence
///     gate — there is nothing to gate.
///
/// Which tier is active is recorded alongside the blob and honored on load.
/// Mixing them within a single vault is impossible by construction.
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
    private let preferProtected: Bool

    init(service: String = "com.freedom.wallet", preferProtected: Bool = true) {
        self.blob = KeychainItem(account: "blob", service: service)
        self.dek = KeychainItem(account: "dek", service: service)
        self.level = KeychainItem(account: "level", service: service)
        self.seKeyTag = Data("\(service).se".utf8)
        self.preferProtected = preferProtected
    }

    var existingLevel: VaultSecurityLevel? {
        guard let data = try? level.read(),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return VaultSecurityLevel(rawValue: s)
    }

    func store(mnemonic: Mnemonic) throws -> VaultSecurityLevel {
        guard let dekBytes = Data.secureRandom(count: 32) else { throw Error.cryptoFailed }

        let resolvedLevel: VaultSecurityLevel
        if preferProtected, let sePublic = try createOrFetchSEPublicKey() {
            let wrapped = try encrypt(dek: dekBytes, with: sePublic)
            try dek.write(wrapped)
            resolvedLevel = .protected
        } else {
            try dek.write(dekBytes)
            resolvedLevel = .deviceBound
        }

        try blob.write(try sealBlob(mnemonic: mnemonic, dek: dekBytes))
        try level.write(Data(resolvedLevel.rawValue.utf8))
        return resolvedLevel
    }

    func load() throws -> Mnemonic {
        guard let resolvedLevel = existingLevel else { throw Error.noVault }
        guard let storedDek = try dek.read(), let sealed = try blob.read() else {
            throw Error.corrupted
        }
        let dekBytes: Data
        switch resolvedLevel {
        case .protected:
            dekBytes = try decrypt(wrappedDek: storedDek, with: try fetchSEPrivateKey())
        case .deviceBound:
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

    // MARK: - Secure Enclave

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
        // Returning nil (not throwing) on SE unavailability is intentional —
        // the caller falls back to .deviceBound storage. No passcode set,
        // simulator quirks, or legacy hardware land here.
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
