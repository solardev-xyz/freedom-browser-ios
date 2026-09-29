import BigInt
import Foundation
import Observation
import web3

/// Process-wide balance cache so every wallet screen shows the last
/// known balances immediately and refreshes them silently — a spinner
/// only when nothing is cached yet, like any other wallet. Keyed by
/// holder address (a vault rotation clears it) and chain.
@MainActor
@Observable
final class WalletBalanceStore {
    typealias Fetch = @MainActor (_ holder: EthereumAddress, _ chain: Chain, _ tokens: [Token]) async -> [Token: BigUInt]

    struct Snapshot: Equatable {
        let balances: [Token: BigUInt]
        let updatedAt: Date
    }

    /// Refreshes closer together than this reuse the snapshot (a screen
    /// popped and pushed again does not hit the network twice).
    static let defaultMinInterval: TimeInterval = 15

    private(set) var snapshots: [Int: Snapshot] = [:]
    private(set) var refreshing: Set<Int> = []
    private(set) var holder: String?

    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var generations: [Int: Int] = [:]

    init(fetch: @escaping Fetch, now: @escaping () -> Date = Date.init) {
        self.fetch = fetch
        self.now = now
    }

    convenience init(registry: ChainRegistry) {
        let fetcher = TokenBalanceFetcher(walletRPC: registry.walletRPC)
        self.init(fetch: { holder, chain, tokens in await fetcher.fetch(holder: holder, chain: chain, tokens: tokens) })
    }

    func balances(on chain: Chain) -> [Token: BigUInt]? {
        snapshots[chain.id]?.balances
    }

    func balance(of token: Token, on chain: Chain) -> BigUInt? {
        snapshots[chain.id]?.balances[token]
    }

    func isRefreshing(_ chain: Chain) -> Bool { refreshing.contains(chain.id) }

    /// Fetch the chain's balances for `holder` and replace the snapshot.
    /// A snapshot younger than `minInterval` is returned as is; a fetch
    /// that yields nothing while a snapshot exists is treated as a
    /// transient failure and leaves the snapshot alone. Returns the
    /// balances now on record, nil when nothing could be learned.
    @discardableResult
    func refresh(
        holder: String, chain: Chain, tokens: [Token]? = nil, minInterval: TimeInterval = WalletBalanceStore.defaultMinInterval
    ) async -> [Token: BigUInt]? {
        if self.holder != holder {
            snapshots.removeAll()
            generations.removeAll()
            self.holder = holder
        }
        if let snapshot = snapshots[chain.id], now().timeIntervalSince(snapshot.updatedAt) < minInterval {
            return snapshot.balances
        }
        let generation = (generations[chain.id] ?? 0) + 1
        generations[chain.id] = generation
        refreshing.insert(chain.id)
        let list = tokens ?? TokenRegistry.tokens(for: chain)
        let result = await fetch(EthereumAddress(holder), chain, list)
        if generations[chain.id] == generation { refreshing.remove(chain.id) }
        guard self.holder == holder, generations[chain.id] == generation else { return snapshots[chain.id]?.balances }
        if result.isEmpty, !list.isEmpty, let existing = snapshots[chain.id] {
            // Every call failed: keep what we know.
            return existing.balances
        }
        // A token whose call failed keeps its last known value: stale
        // beats missing on a balance list.
        var merged = snapshots[chain.id]?.balances ?? [:]
        for (token, value) in result { merged[token] = value }
        snapshots[chain.id] = Snapshot(balances: merged, updatedAt: now())
        return merged
    }

    func invalidate() {
        snapshots.removeAll()
        generations.removeAll()
    }
}
