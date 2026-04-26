import Foundation
import Observation

/// Resolves a chain to its live RPC provider list. Mainnet piggybacks on
/// the ENS pool so its quarantine state is shared across ENS and wallet
/// reads; Gnosis has its own small, hardcoded fallback list.
@MainActor
@Observable
final class ChainRegistry {
    @ObservationIgnored private let mainnetPool: EthereumRPCPool
    /// Lazy so `WalletRPC`'s back-reference to `self` is safe — `self` is
    /// fully initialized by the time any view pulls the RPC.
    @ObservationIgnored lazy var walletRPC: WalletRPC = WalletRPC(registry: self)

    init(mainnetPool: EthereumRPCPool) {
        self.mainnetPool = mainnetPool
    }

    func rpcURLs(for chain: Chain) -> [URL] {
        switch chain {
        case Chain.mainnet: return mainnetPool.availableProviders()
        case Chain.gnosis: return Self.gnosisURLs
        default:
            // Chain is a struct, so this switch isn't exhaustive — `default`
            // catches any future `Chain.*` that forgets to wire itself up.
            // Trap in debug so the miss is loud, empty list in release so
            // the wallet degrades instead of crashing in users' hands.
            assertionFailure("rpcURLs(for:) asked for unknown chain \(chain.displayName)")
            return []
        }
    }

    /// Feeds Mainnet pool quarantine; no-op on Gnosis (hardcoded URL
    /// list, no pool).
    func markSuccess(url: URL, on chain: Chain) {
        if chain == .mainnet { mainnetPool.markSuccess(url) }
    }

    func markFailure(url: URL, on chain: Chain) {
        if chain == .mainnet { mainnetPool.markFailure(url) }
    }

    /// Exposed for tests (see WalletRPCTests) — single source of truth for
    /// what URLs Gnosis queries go to.
    static let gnosisURLs: [URL] = [
        URL(string: "https://rpc.gnosischain.com")!,
        URL(string: "https://rpc.ankr.com/gnosis")!,
        URL(string: "https://gnosis-mainnet.public.blastapi.io")!,
    ]
}
