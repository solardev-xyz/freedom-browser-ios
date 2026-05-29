import Foundation
import Observation

/// Resolves a chain to its live RPC provider pool. Pools are lazily
/// materialized per chain ID from `ChainStore`; the mainnet pool is
/// injected at init so it stays the same instance that `ENSResolver`
/// and `AnchorCorroboration` hold — ENS and wallet share mainnet
/// quarantine state.
@MainActor
@Observable
final class ChainRegistry {
    @ObservationIgnored private let chainStore: ChainStore
    @ObservationIgnored private let mainnetPool: EthereumRPCPool
    @ObservationIgnored private let poolOrderer: ([URL]) -> [URL]
    @ObservationIgnored private var pools: [Int: EthereumRPCPool] = [:]
    /// Lazy so `WalletRPC`'s back-reference to `self` is safe — `self` is
    /// fully initialized by the time any view pulls the RPC.
    @ObservationIgnored lazy var walletRPC: WalletRPC = WalletRPC(registry: self)

    init(
        chainStore: ChainStore,
        mainnetPool: EthereumRPCPool,
        poolOrderer: @escaping ([URL]) -> [URL] = { $0.shuffled() }
    ) {
        self.chainStore = chainStore
        self.mainnetPool = mainnetPool
        self.poolOrderer = poolOrderer
        // Seed the map with the injected mainnet pool so its instance
        // identity is preserved (ENSResolver holds the same reference).
        self.pools[mainnetPool.chainID] = mainnetPool
    }

    func rpcURLs(for chain: Chain) -> [URL] {
        pool(for: chain.id).availableProviders()
    }

    func markSuccess(url: URL, on chain: Chain) {
        pool(for: chain.id).markSuccess(url)
    }

    func markFailure(url: URL, on chain: Chain) {
        pool(for: chain.id).markFailure(url)
    }

    /// Lazily materializes a pool for a chain on first request, then
    /// memoizes — quarantine state must persist across calls for backoff
    /// to be meaningful.
    private func pool(for chainID: Int) -> EthereumRPCPool {
        if let existing = pools[chainID] { return existing }
        let store = chainStore
        let pool = EthereumRPCPool(
            chainID: chainID,
            urlSource: { store.rpcURLs(forChainID: chainID) },
            orderer: poolOrderer
        )
        pools[chainID] = pool
        return pool
    }

    /// Exposed for tests + the chain store seed. Single source of truth
    /// for which URLs ship with Gnosis on first launch.
    static let gnosisURLs: [URL] = [
        URL(string: "https://rpc.gnosischain.com")!,
        URL(string: "https://rpc.ankr.com/gnosis")!,
        URL(string: "https://gnosis-mainnet.public.blastapi.io")!,
    ]
}
