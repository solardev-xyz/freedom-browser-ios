import Foundation
import SwarmKit

/// Builds the `SwarmConfig` we hand to `SwarmNode.start(_:)`. Centralised so
/// `FreedomApp.startNodeIfNeeded` and `BeeIdentityInjector` agree on every
/// boot — same bootnode resolution, same data dir, same password — and a
/// future light-mode upgrade only has to change *here* to pick up everywhere.
@MainActor
enum BeeBootConfig {
    /// Resolve mainnet bootnodes (with the IP-literal fallback for devices
    /// where libp2p's `/dnsaddr/` resolution fails) and assemble a config
    /// pointing at the device's default Bee data dir. Always ultralight in
    /// v1; M6/WP2 introduces the light-mode toggle.
    static func build(password: String) async -> SwarmConfig {
        let fresh = await BootnodeResolver.resolveMainnet()
        let bootnodes = fresh.isEmpty ? SwarmConfig.defaultBootnodes : fresh
        return SwarmConfig(
            dataDir: SwarmNode.defaultDataDir(),
            password: password,
            bootnodes: bootnodes.joined(separator: "|")
        )
    }
}
