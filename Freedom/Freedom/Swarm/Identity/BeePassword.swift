import Foundation
import web3

/// Random per-install password used to encrypt the Bee node's V3 keystore at
/// rest. Stored in Keychain `.deviceOnly` (i.e. `.whenUnlockedThisDeviceOnly`,
/// no iCloud sync) — the password is high-entropy and regenerable, so we'd
/// rather it not leave the device. Constant for the lifetime of an install:
/// rotating it would mean re-encrypting every bee-internal key file in lock-
/// step (libp2p, pss, …), and we already wipe those on identity change for
/// routing-state reasons (`BeeStateDirs`), so password rotation buys nothing.
///
/// Replaces the hardcoded `"freedom-default"` at `FreedomApp.swift` once
/// `BeeIdentityInjector` lands. On vault wipe the password is left in place;
/// Bee regenerates an anonymous identity under the same password, and we
/// avoid an unnecessary Keychain churn on the unlock-then-wipe edge case.
enum BeePassword {
    enum Error: Swift.Error, Equatable {
        case randomFailure
        case keychain(OSStatus)
    }

    private static let item = KeychainItem(
        account: "bee.keystore-password",
        service: "freedom.swarm"
    )

    /// 32 random bytes hex-encoded — 64 ASCII chars. Plenty of entropy for
    /// scrypt's input even with the modest N=32768; matches desktop's
    /// random-32-byte-hex pattern at `identity-manager.js:389`.
    private static let entropyBytes = 32

    /// Read the existing password from Keychain, or generate-and-store one
    /// on first call. Idempotent: subsequent calls on the same install
    /// return the same value.
    static func loadOrCreate() throws -> String {
        if let existing = try readExisting() { return existing }
        guard let bytes = Data.secureRandom(count: entropyBytes) else {
            throw Error.randomFailure
        }
        let password = bytes.web3.hexString.web3.noHexPrefix
        do {
            try item.write(Data(password.utf8), protection: .deviceOnly)
        } catch let KeychainItem.Error.status(s) {
            throw Error.keychain(s)
        }
        return password
    }

    /// Returns the existing password without creating one. Used by the
    /// first-launch migration in `FreedomApp` to detect an install that
    /// pre-dates `BeePassword` (still on the old `"freedom-default"`),
    /// which is the trigger to wipe the legacy bee data dir.
    static func readExisting() throws -> String? {
        do {
            guard let data = try item.read() else { return nil }
            return String(data: data, encoding: .utf8)
        } catch let KeychainItem.Error.status(s) {
            throw Error.keychain(s)
        }
    }

    /// Remove the stored password. Called only on full uninstall-style
    /// reset paths (none in v1 — `Vault.wipe` keeps it). Test-supporting.
    static func wipe() throws {
        do {
            try item.delete()
        } catch let KeychainItem.Error.status(s) {
            throw Error.keychain(s)
        }
    }
}
