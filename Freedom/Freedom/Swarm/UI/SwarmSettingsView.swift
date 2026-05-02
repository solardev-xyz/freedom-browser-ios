import SwarmKit
import SwiftUI

/// Per-section settings page for the embedded Swarm (bee) node.
/// Reachable from the top-level `SettingsView` hub. Mirrors the IPFS
/// settings page's shape, scoped today to a single Enable toggle —
/// node mode (light / ultraLight) and other Swarm-specific controls
/// stay in the Swarm node sheet for now since they're tied to the
/// publish-setup flow.
@MainActor
struct SwarmSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(SwarmNode.self) private var swarm

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Toggle("Enable", isOn: enableBinding)
            } header: {
                Text("Node")
            } footer: {
                Text("Run the embedded Swarm (bee) node on app launch and right now. Disable to free CPU / memory; bzz:// page loads will fail until re-enabled.")
            }

            Section {
                LabeledContent("Status", value: swarm.status.rawValue.capitalized)
                LabeledContent("Mode", value: settings.beeNodeMode.displayName)
                LabeledContent("Connected peers", value: "\(swarm.peerCount)")
            } header: {
                Text("Live")
            }
        }
        .navigationTitle("Swarm")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var enableBinding: Binding<Bool> {
        Binding(
            get: { settings.swarmNodeEnabled },
            set: { newValue in
                settings.swarmNodeEnabled = newValue
                if newValue {
                    Task { await SwarmRuntime.enable(swarm: swarm, settings: settings) }
                } else {
                    swarm.stop()
                }
            }
        )
    }
}
