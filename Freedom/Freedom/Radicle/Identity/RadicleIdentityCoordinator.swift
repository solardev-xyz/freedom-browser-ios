import Foundation
import Observation
import RadicleKit

/// Starts the embedded Radicle node with the identity the recovery
/// phrase derives (desktop: Radicle identity from the same seed).
enum RadicleRuntime {
    static let alias = "freedom-ios"

    /// Boot with the stored seed-derived key when there is one, else
    /// the profile's own key; then dial the seeds once.
    @MainActor
    static func start(_ radicle: RadicleNode) async {
        let key = try? RadicleIdentityStore.shared.load()
        await radicle.start(alias: alias, key: key)
        guard radicle.status == .running else { return }
        _ = await radicle.connectSeeds()
    }
}

/// Keeps the node's identity in step with the vault: a created or
/// imported phrase stores its Radicle key and restarts the node under
/// it; a wiped vault deletes the key and the node restarts anonymous.
/// Silent by design — pre-release, and desktop swaps the same way.
@MainActor
@Observable
final class RadicleIdentityCoordinator {
    private(set) var isSwapping = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let store: RadicleIdentityStore

    init(store: RadicleIdentityStore = .shared) {
        self.store = store
    }

    /// Idempotent: compares what the vault would derive with what is
    /// stored and what the running node reports, and only acts on a
    /// difference. Called on vault and node state changes.
    func checkAndHeal(vault: Vault, radicle: RadicleNode) {
        guard task == nil else { return }
        switch vault.state {
        case .unlocked:
            guard let seed = try? vault.bip39Seed(), let key = try? RadicleIdentityKey.derive(fromSeed: seed) else { return }
            if (try? store.load()) != key.privateKey { try? store.save(key.privateKey) }
            if radicle.status == .running, radicle.identity?.did != key.did {
                restart(radicle)
            }
        case .empty:
            guard (try? store.load()) != nil else { return }
            try? store.delete()
            if radicle.status == .running { restart(radicle) }
        case .locked:
            break
        }
    }

    private func restart(_ radicle: RadicleNode) {
        isSwapping = true
        task = Task { [weak self] in
            await radicle.shutdown()
            await RadicleRuntime.start(radicle)
            self?.isSwapping = false
            self?.task = nil
        }
    }
}

