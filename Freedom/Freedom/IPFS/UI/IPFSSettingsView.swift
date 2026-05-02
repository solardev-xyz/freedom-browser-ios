import IPFSKit
import SwiftUI

/// Per-section settings page for the embedded kubo node. Reachable from
/// the top-level `SettingsView` hub. Changes write through to
/// `SettingsStore` immediately; the kubo node is restarted when the
/// user navigates back, so a quick toggle-and-revert does no work.
@MainActor
struct IPFSSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(IPFSNode.self) private var ipfs

    /// Snapshot taken on appear. Compared against current values on
    /// disappear — restart is only triggered when something actually
    /// changed, so opening the page and leaving without touching
    /// anything is a no-op.
    @State private var initialRoutingMode: IPFSRoutingMode?
    @State private var initialLowPower: Bool?

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Toggle("Enable", isOn: enableBinding)
            } footer: {
                Text("Run the embedded IPFS (kubo) node on app launch and right now. Disable to free CPU / memory; ipfs:// page loads will fail until re-enabled.")
            }

            Section {
                Picker("Routing", selection: $settings.ipfsRoutingMode) {
                    ForEach(IPFSRoutingMode.allCases, id: \.self) { mode in
                        Text(displayName(mode)).tag(mode)
                    }
                }
                Toggle("Low power", isOn: $settings.ipfsLowPower)
            } header: {
                Text("Routing")
            } footer: {
                Text(footerText)
            }

            Section {
                LabeledContent("Status", value: ipfs.status.rawValue.capitalized)
                LabeledContent("Active routing", value: ipfs.activeRoutingMode.rawValue)
                LabeledContent("Active power", value: ipfs.activeLowPower ? "low" : "default")
            } header: {
                Text("Live")
            } footer: {
                Text("Settings apply on the next node restart. Leaving this page restarts the node automatically if anything changed.")
            }
        }
        .navigationTitle("IPFS")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            initialRoutingMode = settings.ipfsRoutingMode
            initialLowPower = settings.ipfsLowPower
        }
        .onDisappear {
            applyIfChanged()
        }
    }

    private var footerText: String {
        switch settings.ipfsRoutingMode {
        case .autoclient: "Hybrid: delegated routing + light DHT. Cheapest, default."
        case .dhtclient:  "DHT lookups only. No delegated routing — slightly higher reachability cost, no third-party trust."
        case .dht:        "Full DHT participation. Highest battery / bandwidth use; fully decentralised content routing."
        case .disabled:   "No content routing. Gateway-only mode — works for content already pinned locally."
        }
    }

    private func displayName(_ mode: IPFSRoutingMode) -> String {
        switch mode {
        case .autoclient: "Auto"
        case .dhtclient:  "Light DHT"
        case .dht:        "Full DHT"
        case .disabled:   "Off"
        }
    }

    private var enableBinding: Binding<Bool> {
        Binding(
            get: { settings.ipfsNodeEnabled },
            set: { newValue in
                settings.ipfsNodeEnabled = newValue
                if newValue {
                    let config = settings.ipfsConfig(dataDir: IPFSNode.defaultDataDir())
                    ipfs.start(config)
                } else {
                    ipfs.stop()
                }
            }
        )
    }

    private func applyIfChanged() {
        guard let initialRoutingMode, let initialLowPower else { return }
        let changed =
            initialRoutingMode != settings.ipfsRoutingMode
            || initialLowPower != settings.ipfsLowPower
        guard changed else { return }
        let config = settings.ipfsConfig(dataDir: IPFSNode.defaultDataDir())
        Task { await ipfs.restart(config) }
    }
}
