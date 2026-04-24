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
        /// Never leaves the device. No biometric gate. Used by the
        /// `protected` and `deviceBound` tiers.
        case deviceOnly
        /// iCloud-Keychain synced (`.whenUnlocked` + `synchronizable`). No
        /// `SecAccessControl` — iCloud Keychain silently refuses to sync
        /// items with access control flags, so user-presence gating has
        /// to happen at the app layer via `LAContext.evaluatePolicy` on
        /// the read side.
        case cloudSynced
    }

    let account: String
    let service: String

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
        }
    }
}
