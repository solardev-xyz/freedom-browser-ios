import Foundation
import SwarmKit

/// Runtime helpers for starting the embedded Swarm (bee) node from
/// places other than the launch-time `FreedomApp.startNodeIfNeeded`.
/// Specifically: the Swarm node sheet's Enable toggle and the Swarm
/// settings page's Enable toggle, both of which need to (re)boot bee
/// after the user flips the persisted `swarmNodeEnabled` setting.
///
/// Mirrors the launch-time boot path minus the legacy-install detection
/// — that one-shot wipe only matters on the very first install and
/// isn't a concern at runtime toggle time.
@MainActor
enum SwarmRuntime {
    /// Boot bee with the current persisted settings (mode, password).
    /// Errors print to console; the user can re-toggle to retry.
    static func enable(swarm: SwarmNode, settings: SettingsStore) async {
        do {
            let password = try BeePassword.loadOrCreate()
            let config = await BeeBootConfig.build(password: password, mode: settings.beeNodeMode)
            swarm.start(config)
        } catch {
            print("SwarmRuntime.enable failed: \(error)")
        }
    }
}
