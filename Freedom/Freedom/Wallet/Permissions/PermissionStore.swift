import Foundation
import Observation
import OSLog
import SwiftData

private let log = Logger(subsystem: "com.browser.Freedom", category: "PermissionStore")

/// Persisted dapp-permission grants. Every RPC call that reaches the
/// bridge hits `isConnected` / `accounts(for:)` — those read from an
/// in-memory `[origin: account]` map, not SwiftData, so the hot path is
/// O(1). Grant / revoke keep the map and the backing store in sync.
///
/// Revoke posts `.walletPermissionRevoked` with the origin key in
/// `userInfo["origin"]`; bridges observe and emit `accountsChanged`/
/// `disconnect` to any live tab whose origin matches.
@MainActor
@Observable
final class PermissionStore {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var accountByOrigin: [String: String]

    init(context: ModelContext) {
        self.context = context
        let descriptor = FetchDescriptor<DappPermission>()
        let fetched = (try? context.fetch(descriptor)) ?? []
        self.accountByOrigin = Dictionary(
            uniqueKeysWithValues: fetched.map { ($0.origin, $0.account) }
        )
    }

    func grant(origin: String, account: String) {
        if let existing = fetch(origin: origin) {
            existing.account = account
            existing.lastUsedAt = .now
        } else {
            context.insert(DappPermission(origin: origin, account: account))
        }
        accountByOrigin[origin] = account
        save()
    }

    func revoke(origin: String) {
        guard let existing = fetch(origin: origin) else { return }
        context.delete(existing)
        accountByOrigin[origin] = nil
        save()
        NotificationCenter.default.post(
            name: .walletPermissionRevoked,
            object: nil,
            userInfo: ["origin": origin]
        )
    }

    func isConnected(_ origin: String) -> Bool {
        accountByOrigin[origin] != nil
    }

    func accounts(for origin: String) -> [String] {
        accountByOrigin[origin].map { [$0] } ?? []
    }

    func touchLastUsed(origin: String) {
        guard let grant = fetch(origin: origin) else { return }
        grant.lastUsedAt = .now
        save()
    }

    private func fetch(origin: String) -> DappPermission? {
        let descriptor = FetchDescriptor<DappPermission>(
            predicate: #Predicate { $0.origin == origin }
        )
        return try? context.fetch(descriptor).first
    }

    private func save() { context.saveLogging("DappPermission", to: log) }
}

