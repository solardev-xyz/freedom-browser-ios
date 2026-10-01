import Foundation
import SwarmKit

/// Builds the `SwarmConfig` we hand to `SwarmNode.start(_:)`. Centralised so
/// `FreedomApp.startNodeIfNeeded` and `BeeIdentityInjector` agree on every
/// boot — same bootnode resolution, same data dir, same password, same
/// chain access.
@MainActor
enum BeeBootConfig {
    /// Resolve mainnet bootnodes (with the IP-literal fallback for devices
    /// where libp2p's `/dnsaddr/` resolution fails) and assemble a config
    /// pointing at the device's default data dir. The node always gets
    /// chain access: ant has no light/ultra-light modes any more (desktop
    /// #459 dropped the switch too); the RPC URL is the switch that makes
    /// ant build a chain client, and the installed chain transport then
    /// routes its requests through the app's chain-data router. A node
    /// that never bought storage pays nothing for it: ant's startup chain
    /// block only reads.
    static func build(password: String) async -> SwarmConfig {
        let fresh = await BootnodeResolver.resolveMainnet()
        let bootnodes = fresh.isEmpty ? SwarmConfig.defaultBootnodes : fresh
        return SwarmConfig(
            dataDir: SwarmNode.defaultDataDir(),
            password: password,
            rpcEndpoint: SwarmDefaults.pinnedGnosisRPC,
            bootnodes: bootnodes.joined(separator: "|")
        )
    }
}
