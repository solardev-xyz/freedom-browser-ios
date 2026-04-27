import Foundation
import SwarmKit

/// Builds the `SwarmConfig` we hand to `SwarmNode.start(_:)`. Centralised so
/// `FreedomApp.startNodeIfNeeded` and `BeeIdentityInjector` agree on every
/// boot — same bootnode resolution, same data dir, same password — and the
/// light-mode upgrade only has to change *here* to pick up everywhere.
@MainActor
enum BeeBootConfig {
    /// Resolve mainnet bootnodes (with the IP-literal fallback for devices
    /// where libp2p's `/dnsaddr/` resolution fails) and assemble a config
    /// pointing at the device's default Bee data dir. The `mode` selects
    /// ultralight (no chain) or light (pinned Gnosis RPC + chequebook +
    /// swap-enable).
    static func build(password: String, mode: BeeNodeMode) async -> SwarmConfig {
        let fresh = await BootnodeResolver.resolveMainnet()
        let bootnodes = fresh.isEmpty ? SwarmConfig.defaultBootnodes : fresh
        return SwarmConfig(
            dataDir: SwarmNode.defaultDataDir(),
            password: password,
            rpcEndpoint: rpcEndpoint(for: mode),
            bootnodes: bootnodes.joined(separator: "|")
        )
    }

    /// Bee-lite reads `swap-enable` from `rpcEndpoint != nil`. Ultralight
    /// passes nil; light mode pins the Gnosis RPC. The pinned URL is
    /// independent of `ChainRegistry`'s Gnosis pool (used for our own
    /// eth_calls) so either path can migrate without touching the other.
    private static func rpcEndpoint(for mode: BeeNodeMode) -> String? {
        switch mode {
        case .ultraLight: return nil
        case .light: return SwarmFunderConstants.pinnedGnosisRPC
        }
    }
}
