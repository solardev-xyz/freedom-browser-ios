import IPFSKit
import SwiftUI

/// Per-section settings page for the embedded IPFS reader (Rust
/// `freedom-ipfs`). Reachable from the top-level `SettingsView` hub.
/// Changes write through to `SettingsStore` immediately; the gateway
/// is restarted when the user navigates back, so a quick
/// toggle-and-revert does no work.
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
                Text("Run the embedded IPFS reader on app launch and right now. Disable to free CPU / memory; ipfs:// page loads will fail until re-enabled.")
            }

            Section {
                Picker("Routing", selection: $settings.ipfsRoutingMode) {
                    ForEach(visibleRoutingModes, id: \.self) { mode in
                        Text(displayName(mode)).tag(mode)
                    }
                }
                Toggle("Low resource", isOn: $settings.ipfsLowPower)
            } header: {
                Text("Routing")
            } footer: {
                Text(footerText)
            }

            Section {
                Picker("Gateway transport", selection: $settings.ipfsGatewayTransport) {
                    ForEach(IPFSGatewayTransport.allCases, id: \.self) { transport in
                        Text(transportDisplayName(transport)).tag(transport)
                    }
                }
            } header: {
                Text("Transport (experimental)")
            } footer: {
                Text(transportFooterText)
            }

            Section {
                LabeledContent("Status", value: ipfs.status.rawValue.capitalized)
                LabeledContent("Active routing", value: ipfs.activeRoutingMode.rawValue)
                LabeledContent("Active budget", value: ipfs.activeLowPower ? "low" : "default")
                if let gateway = ipfs.gatewayURL {
                    LabeledContent("Gateway", value: gateway.absoluteString)
                }
                if let diag = ipfs.diagnostics {
                    LabeledContent(
                        "Cache",
                        value: "\(diag.stats.blockCount) blocks · " +
                            ByteCountFormatter.string(
                                fromByteCount: Int64(diag.stats.totalBytes),
                                countStyle: .file
                            )
                    )
                    LabeledContent("Preloads", value: "\(diag.activePreloadCount)")
                }
            } header: {
                Text("Live")
            } footer: {
                Text("Settings apply on the next gateway restart. Leaving this page restarts the gateway automatically if anything changed.")
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

    /// `dht` and `dhtclient` both map to the Rust reader's `.lightDht`
    /// — hide the redundant `dht` row from the picker so the user
    /// doesn't see two synonymous options. The case stays in the enum
    /// so settings persisted from earlier builds still load.
    private var visibleRoutingModes: [IPFSRoutingMode] {
        IPFSRoutingMode.allCases.filter { $0 != .dht }
    }

    private var footerText: String {
        switch settings.ipfsRoutingMode {
        case .autoclient: "Hybrid: delegated routing + light DHT fallback. Cheapest, default."
        case .dhtclient, .dht: "Light DHT only. No delegated routing — slightly higher reachability cost, no third-party trust."
        case .disabled:   "Cache-only. The local gateway serves blocks already cached; no online retrieval."
        }
    }

    private func displayName(_ mode: IPFSRoutingMode) -> String {
        switch mode {
        case .autoclient: "Auto"
        case .dhtclient, .dht:  "Light DHT"
        case .disabled:   "Off"
        }
    }

    private func transportDisplayName(_ transport: IPFSGatewayTransport) -> String {
        switch transport {
        case .loopbackHTTP: "Loopback HTTP"
        case .nativeFFI:    "Native FFI"
        }
    }

    private var transportFooterText: String {
        switch settings.ipfsGatewayTransport {
        case .loopbackHTTP:
            "Default. ipfs:// requests go through URLSession to http://127.0.0.1:<port> on the embedded Rust gateway."
        case .nativeFFI:
            "Experimental. Requests bypass URLSession and the loopback HTTP listener; the scheme handler drives GatewayCore through the native FFI directly. Applies to the next request."
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
        // Don't restart a disabled node — the user has explicitly
        // toggled IPFS off (the enable binding already called
        // `ipfs.stop()`). Without this guard, changing routing or
        // low-power and then disabling-and-leaving would restart the
        // gateway right after stopping it.
        guard settings.ipfsNodeEnabled else { return }
        guard let initialRoutingMode, let initialLowPower else { return }
        let changed =
            initialRoutingMode != settings.ipfsRoutingMode
            || initialLowPower != settings.ipfsLowPower
        guard changed else { return }
        let config = settings.ipfsConfig(dataDir: IPFSNode.defaultDataDir())
        Task { await ipfs.restart(config) }
    }
}
