import Foundation

/// Resolves a chain to its live RPC provider list. Mainnet piggybacks on
/// the ENS pool so its quarantine state is shared across ENS and wallet
/// reads; Gnosis has its own small, hardcoded fallback list.
@MainActor
final class ChainRegistry {
    private let mainnetPool: EthereumRPCPool

    init(mainnetPool: EthereumRPCPool) {
        self.mainnetPool = mainnetPool
    }

    func rpcURLs(for chain: Chain) -> [URL] {
        switch chain {
        case Chain.mainnet: return mainnetPool.availableProviders()
        case Chain.gnosis: return Self.gnosisURLs
        default: return []
        }
    }

    /// Exposed for tests (see WalletRPCTests.stubResponses) — single source
    /// of truth for what URLs Gnosis queries go to.
    static let gnosisURLs: [URL] = [
        URL(string: "https://rpc.gnosischain.com")!,
        URL(string: "https://rpc.ankr.com/gnosis")!,
        URL(string: "https://gnosis-mainnet.public.blastapi.io")!,
    ]
}
