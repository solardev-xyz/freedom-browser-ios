import SwiftUI
import SwarmKit
import IPFSKit
import MyotisKit
import RadicleKit

/// The "Nodes" drawer — a medium-detent bottom sheet with one LIVE row
/// per node. This exists because menus are UIKit snapshots: any ticking
/// value (peer counts) forces a rebuild, which made an in-menu nodes
/// submenu re-collapse while open. The drawer is ordinary SwiftUI, so
/// rows update in place; the menu keeps only a one-line summary.
///
/// Rows push the node's home view inside the drawer's own
/// NavigationStack (standard iOS drill-in) — the same content the
/// standalone node sheets present, minus their modal chrome. All five
/// nodes are always listed: a disabled node shows "Off" and its page
/// carries the enable toggle.
struct NodesDrawer: View {
    @Environment(SwarmNode.self) private var swarm
    @Environment(IPFSNode.self) private var ipfs
    @Environment(MyotisNode.self) private var myotis
    @Environment(RadicleNode.self) private var radicle
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                row(icon: "NodeSwarm", name: "Swarm", detail: peerLine(
                    running: swarm.status == .running,
                    status: swarm.status.rawValue,
                    peers: swarm.peerCount
                )) {
                    NodeHomeView().navigationTitle("Swarm node")
                }
                row(
                    icon: "NodeIPFS", name: "IPFS",
                    detail: ipfs.status == .running
                        ? "Online" : ipfs.status.rawValue.capitalized
                ) {
                    IpfsNodeHomeView().navigationTitle("IPFS node")
                }
                row(icon: "NodeRadicle", name: "Radicle", detail: peerLine(
                    running: radicle.status == .running,
                    status: radicle.status.rawValue,
                    peers: radicle.connectedPeers
                )) {
                    RadicleNodeHomeView().navigationTitle("Radicle")
                }
                row(
                    icon: "NodeEthereum", name: "Ethereum",
                    detail: chainLine(MyotisNetwork.mainnet)
                ) {
                    MyotisNodeHomeView().navigationTitle("Light client")
                }
                row(
                    icon: "NodeGnosis", name: "Gnosis",
                    detail: chainLine(MyotisNetwork.gnosis)
                ) {
                    MyotisNodeHomeView().navigationTitle("Light client")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Nodes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(
        icon: String, name: String, detail: String,
        @ViewBuilder destination: @escaping () -> some View
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            .animation(.default, value: detail)
        }
    }

    private func peerLine(running: Bool, status: String, peers: Int) -> String {
        guard running else { return status.capitalized }
        guard peers > 0 else { return "Connecting…" }
        return "Online · \(peers) peer\(peers == 1 ? "" : "s")"
    }

    private func chainLine(_ network: MyotisNetwork) -> String {
        let chain = myotis.chainStatus[network.chainId]
        let state = MyotisMenuLine.state(nodeStatus: myotis.status, chain: chain)
        let peers = MyotisMenuLine.totalPeers(chain)
        guard peers > 0, state == "Verified" || state == "Syncing" else { return state }
        return "\(state) · \(peers) peer\(peers == 1 ? "" : "s")"
    }
}
