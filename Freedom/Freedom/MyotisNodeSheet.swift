import MyotisKit
import SwiftUI

/// Modal sheet for the embedded Myotis light client — sibling of
/// `NodeSheet` (Swarm) and `IpfsNodeSheet` (IPFS). Opened from either
/// chain row in the node menu: one engine, per-chain detail inside.
@MainActor
struct MyotisNodeSheet: View {
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            MyotisNodeHomeView()
                .navigationTitle("Light client")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { isPresented = false }
                    }
                }
        }
    }
}

/// Container view for the embedded light client: enable kill switch,
/// one status card per chain, and the diagnostic log. There are
/// deliberately no tuning knobs — the engine is tuned for mobile and
/// the resolution order is fixed (Light client first, then the method
/// chosen under ENS settings).
@MainActor
struct MyotisNodeHomeView: View {
    @Environment(MyotisNode.self) private var myotis
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                enableCard
                if settings.myotisNodeEnabled {
                    ForEach(MyotisNetwork.allCases, id: \.self) { network in
                        chainCard(network)
                    }
                    logsLink
                }
            }
            .padding(20)
        }
    }

    private var enableCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Enable")
                    .font(.headline)
                Text("Verify Ethereum & Gnosis peer-to-peer on this device")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Enable", isOn: enableBinding)
                .labelsHidden()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func chainCard(_ network: MyotisNetwork) -> some View {
        let status = myotis.chainStatus[network.chainId]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(network == .mainnet ? "NodeEthereum" : "NodeGnosis")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.primary)
                Text(network == .mainnet ? "Ethereum" : "Gnosis")
                    .font(.headline)
                Spacer()
                Text(MyotisMenuLine.state(nodeStatus: myotis.status, chain: status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let status {
                // Two DIFFERENT P2P networks, not a subset relationship:
                // beacon = consensus-layer libp2p, state = execution-layer
                // snap pool. Labeled so they don't read as one hierarchy.
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    detailRow("Beacon peers", "\(status.peerCount)")
                    detailRow("State peers", "\(status.snapPeers)")
                    if status.executionBlockNumber > 0 {
                        detailRow("Verified head", "\(status.executionBlockNumber)")
                    }
                    if status.finalizedBlockNumber > 0 {
                        detailRow("Finalized", "\(status.finalizedBlockNumber)")
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .monospacedDigit()
        }
    }

    private var logsLink: some View {
        NavigationLink {
            MyotisNodeLogView()
        } label: {
            HStack {
                Text("Diagnostic logs")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
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

/// Full light-client log surface — diagnostic-only, same shape as the
/// Swarm/IPFS log views. Includes the engine's own drained tracing
/// lines, so "stuck finding state peers" is debuggable in the field.
@MainActor
struct MyotisNodeLogView: View {
    @Environment(MyotisNode.self) private var myotis

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if myotis.log.isEmpty {
                    Text("No log entries yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(myotis.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Pure formatting for the chain rows in the node menu and the state
/// tag on the sheet's chain cards — kept view-free so the wording
/// decision table is unit-testable.
enum MyotisMenuLine {
    /// "Verified" | "Syncing" | "Starting" | "Off" | "Failed" — the
    /// one-word state for a chain given the engine's lifecycle status
    /// and that chain's decoded status.
    static func state(nodeStatus: MyotisStatus, chain: MyotisChainStatus?) -> String {
        switch nodeStatus {
        case .idle, .stopping, .stopped: return "Off"
        case .failed: return "Failed"
        case .starting: return "Starting"
        case .running: break
        }
        guard let chain else { return "Starting" }
        if chain.ready { return "Verified" }
        if chain.paused { return "Paused" }
        return "Syncing"
    }

    /// Live peer connections across BOTH of the chain's P2P networks:
    /// consensus-layer libp2p peers (`peerCount`) + the execution-layer
    /// snap pool (`snapPeers`). Disjoint networks, so the sum is a real
    /// count of open connections, not double-counting.
    static func totalPeers(_ chain: MyotisChainStatus?) -> Int {
        guard let chain else { return 0 }
        return chain.peerCount + chain.snapPeers
    }

    /// The full menu row line, Swarm-symmetric: the peer count IS the
    /// happy-path status ("Ethereum · 9 peers" — verified reads are
    /// served), a state word otherwise. While syncing, a nonzero count
    /// is appended so warm-up reads as progress instead of a stall.
    /// "Verified" as a claim lives in the trust shield per resolution,
    /// not as a static menu label.
}
