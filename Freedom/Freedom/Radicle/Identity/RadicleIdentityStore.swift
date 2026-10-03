import Foundation

/// The Radicle secret seed between launches. The node boots at app
/// launch while the vault is still locked, so the 32 bytes derived at
/// vault create / import are kept in the Keychain (device-only, no
/// iCloud, no biometric gate — the same posture as the Swarm keystore
/// password) and handed to libradicle in memory. A vault wipe deletes
/// them and the node falls back to its own generated key.
struct RadicleIdentityStore {
    static let shared = RadicleIdentityStore(item: KeychainItem(account: "radicle.node-key", service: "freedom.radicle"))

    private let item: KeychainItem

    init(item: KeychainItem) { self.item = item }

    func load() throws -> Data? {
        guard let data = try item.read(), data.count == 32 else { return nil }
        return data
    }

    func save(_ key: Data) throws {
        precondition(key.count == 32, "Radicle secret seed must be 32 bytes")
        try item.write(key, protection: .deviceOnly)
    }

    func delete() throws { try item.delete() }
}
