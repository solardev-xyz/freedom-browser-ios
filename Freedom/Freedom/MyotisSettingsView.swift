import MyotisKit
import SwiftUI

/// Per-section settings page for the embedded Myotis Ethereum light
/// client. Mirrors the Swarm settings page's shape: one Enable toggle
/// (the kill switch — the client is on by default) plus live per-chain
/// status. There is deliberately nothing else to configure: resolution
/// ordering is fixed (Myotis first, then the method chosen on the ENS
/// page), and the engine tunes itself for mobile.
@MainActor
struct MyotisSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(MyotisNode.self) private var myotis

    var body: some View {
        Form {
            Section {
                Toggle("Enable", isOn: enableBinding)
            } header: {
                Text("Ethereum Light Client")
            } footer: {
                Text("Verify Ethereum and Gnosis data peer-to-peer on this device — no RPC provider or prover in the loop. When the client is syncing or unavailable, lookups automatically fall back to the method chosen under ENS settings.")
            }

            Section {
                LabeledContent("Status", value: myotis.status.rawValue.capitalized)
                ForEach(MyotisNetwork.allCases, id: \.self) { network in
                    chainRow(network)
                }
            } header: {
                Text("Live")
            }
        }
        .navigationTitle("Light Client")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func chainRow(_ network: MyotisNetwork) -> some View {
        let status = myotis.chainStatus[network.chainId]
        LabeledContent(network.rawValue.capitalized) {
            if let status {
                Text(chainSummary(status))
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }

    private func chainSummary(_ status: MyotisChainStatus) -> String {
        guard status.running else { return "stopped" }
        if status.paused { return "paused" }
        guard status.beaconState == "SYNCED" else {
            return status.beaconState.isEmpty ? "starting" : status.beaconState.lowercased()
        }
        let readiness = status.ready ? "verified reads" : "finding state peers"
        return "synced · \(status.peerCount) peers · \(readiness)"
    }

    private var enableBinding: Binding<Bool> {
        Binding(
            get: { settings.myotisNodeEnabled },
            set: { newValue in
                settings.myotisNodeEnabled = newValue
                if newValue {
                    myotis.start()
                } else {
                    myotis.stop()
                }
            }
        )
    }
}
