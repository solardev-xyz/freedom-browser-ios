import Foundation
import Security

struct KeychainItem {
    enum Error: Swift.Error, Equatable {
        case status(OSStatus)
    }

    /// How an item is stored. The `kSecAttrSynchronizable` mismatch gotcha
    /// — that a query without the attribute silently skips synchronizable
    /// items — is handled by read/delete using `kSecAttrSynchronizableAny`,
    /// so this enum only needs to describe what to write.
    enum Protection {
        /// Never leaves the device. No biometric gate.
        /// Historical default; used by the `protected` and `deviceBound` tiers.
        case deviceOnly
        /// iCloud-Keychain synced, device-wide. No biometric gate — for
        /// metadata the caller wants visible across the user's devices
        /// without gating (e.g. the tier marker, the encrypted blob when
        /// the gate is held by the DEK item).
        case cloudSynced
        /// iCloud-Keychain synced and gated by `.userPresence` (biometric
        /// or passcode). Used for the DEK in the cloudSynced tier — reading
        /// it triggers the system auth prompt on this device.
        case cloudSyncedGated
    }

    let account: String
    var service: String = "com.freedom.wallet"

    func read() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess: return out as? Data
        case errSecItemNotFound: return nil
        default: throw Error.status(status)
        }
    }

    func write(_ data: Data, protection: Protection = .deviceOnly) throws {
        // Update-then-add-on-not-found avoids the TOCTOU race that
        // check-existence-first has against a shared Keychain.
        // Match-on-update uses SyncAny so we replace an existing item
        // regardless of its previous sync setting — matters during tier
        // migrations (e.g. reconfiguring a vault that was deviceBound).
        var matchQuery = baseQuery
        matchQuery[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny

        let attrs = try attributes(for: data, protection: protection)
        var status = SecItemUpdate(matchQuery as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            let add = baseQuery.merging(attrs) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Error.status(status) }
    }

    func delete() throws {
        var query = baseQuery
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Error.status(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func attributes(for data: Data, protection: Protection) throws -> [String: Any] {
        switch protection {
        case .deviceOnly:
            return [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                kSecAttrSynchronizable as String: false,
            ]
        case .cloudSynced:
            return [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
                kSecAttrSynchronizable as String: true,
            ]
        case .cloudSyncedGated:
            var accessError: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlocked,
                [.userPresence],
                &accessError
            ) else {
                throw Error.status(errSecParam)
            }
            return [
                kSecValueData as String: data,
                kSecAttrAccessControl as String: access,
                kSecAttrSynchronizable as String: true,
            ]
        }
    }
}
