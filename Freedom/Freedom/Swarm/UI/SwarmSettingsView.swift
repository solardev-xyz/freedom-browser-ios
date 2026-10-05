import SwarmKit
import SwiftUI

/// Per-section settings page for the embedded Swarm (bee) node.
/// Reachable from the top-level `SettingsView` hub. Mirrors the IPFS
/// settings page's shape, scoped today to a single Enable toggle —
/// other Swarm-specific controls stay in the Swarm node sheet for now
/// since they're tied to the publish-setup flow.
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
                Toggle("Pay peers for faster Swarm", isOn: Binding(
                    get: { settings.swarmSwapEnabled },
                    set: { newValue in
                        settings.swarmSwapEnabled = newValue
                        swarm.setSwapEnabled(newValue)
                    }
                ))
            } header: {
                Text("Bandwidth")
            } footer: {
                Text("Your node pays other nodes small amounts of xBZZ from its chequebook for uploads and for downloads faster than the free tier — up to about 0.75 xBZZ per GB. Off keeps browsing on the free tier (around 5–6 Mbit/s), and large uploads can stall.")
            }

            Section {
                NavigationLink("App permissions") { SwarmManifestSettingsView() }
            } header: {
                Text("Apps")
            } footer: {
                Text("Swarm apps that declare their permissions up front, and whether you let the declaration apply or kept asking each time.")
            }

            Section {
                LabeledContent("Status", value: swarm.status.rawValue.capitalized)
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
