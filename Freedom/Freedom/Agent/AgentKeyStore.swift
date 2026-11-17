import Foundation
import OSLog

private let log = Logger(subsystem: "com.browser.Freedom", category: "AgentEngine")

/// The agent's model-provider API keys, one per provider, in the Keychain
/// (this device only, readable while unlocked). The engine gets them in
/// memory when it opens; its database never stores them.
enum AgentKeyStore {
    private static let service = "com.browser.Freedom.agent.provider-key"

    static func key(for provider: String) -> String? {
        do {
            guard let data = try KeychainItem(account: provider, service: service).read() else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            log.error("[keys] read \(provider, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Saves `key`, or removes the stored one when `key` is empty.
    static func setKey(_ key: String, for provider: String) throws {
        let item = KeychainItem(account: provider, service: service)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try item.delete()
        } else {
            try item.write(Data(trimmed.utf8), protection: .deviceOnly)
        }
    }

    static func hasKey(for provider: String) -> Bool { key(for: provider)?.isEmpty == false }

    /// Every stored key, for the engine.
    static func allKeys(_ providers: [String]) -> [String: String] {
        var keys: [String: String] = [:]
        for provider in providers {
            if let key = key(for: provider), !key.isEmpty { keys[provider] = key }
        }
        return keys
    }
}
