import Foundation
import Security

struct KeychainItem {
    enum Error: Swift.Error, Equatable {
        case status(OSStatus)
    }

    let account: String
    var service: String = "com.freedom.wallet"

    func read() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess: return out as? Data
        case errSecItemNotFound: return nil
        default: throw Error.status(status)
        }
    }

    func write(_ data: Data, accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) throws {
        // Update-then-add-on-not-found avoids the TOCTOU race that
        // check-existence-first has against a shared Keychain.
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible,
            kSecAttrSynchronizable as String: false,
        ]
        var status = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            let add = baseQuery.merging(attrs) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Error.status(status) }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
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
}
