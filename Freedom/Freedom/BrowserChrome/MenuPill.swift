import SwiftUI
import SwarmKit
import IPFSKit

/// Catch-all menu pill. The label is the ambient `NodeStatusIcon` (red
/// dot when off, green with arcs by peer count) instead of an ellipsis.
///
/// The Menu's content is laid out *bottom-up* in code: iOS reverses the
/// section order for menus attached to a bottom-of-screen button so the
/// item closest to the user's finger is first in code. We follow that
/// convention so the visual top-down order matches the user's spec.
struct MenuPill: View {
    let swarmSegment: NodeSegmentState
    let ipfsSegment: NodeSegmentState
    let ethereumSegment: NodeSegmentState
    let gnosisSegment: NodeSegmentState
    let swarmStatsLine: String
    let ipfsStatsLine: String
    let ethereumStatsLine: String
    let gnosisStatsLine: String

    let isURLBookmarked: Bool
    let canBookmark: Bool
    let shareURL: URL?

    let onBookmarkToggle: () -> Void
    let onTabs: () -> Void
    let onNewTab: () -> Void
    let onWallet: () -> Void
    let onSwarmNode: () -> Void
    let onIpfsNode: () -> Void
    let onLightClient: () -> Void
    let onSettings: () -> Void

    var body: some View {
        Menu {
            // Bottom-most section: page actions (Share, Bookmark).
            // System Menu doesn't render `ControlGroup`'s side-by-side
            // layout reliably here, so each is its own row.
            Section {
                if let url = shareURL {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                Button(action: onBookmarkToggle) {
                    Label("Bookmark", systemImage: isURLBookmarked ? "star.fill" : "star")
                }
                .disabled(!canBookmark)
            }

            Section {
                Button(action: onTabs) {
                    Label("Tabs", systemImage: "square.on.square")
                }
                Button(action: onNewTab) {
                    Label("New tab", systemImage: "plus.square")
                }
            }

            Section {
                Button(action: onSettings) {
                    Label("Settings", systemImage: "gear")
                }
            }

            Section {
                Button(action: onWallet) {
                    Label("Wallet", systemImage: "creditcard.fill")
                }
            }

            // Top-most section: tappable node entries grouped under one
            // "Nodes" header. Each row's label already carries the node
            // name + live state, so the section header just frames
            // them. Per the bottom-up convention the code order is the
            // REVERSE of the visual: Ethereum tops the visual menu,
            // then Gnosis, Swarm, IPFS. Both chain rows open the same
            // light-client sheet (one engine, per-chain detail inside).
            Section("Nodes") {
                Button(action: onIpfsNode) {
                    Label { Text(ipfsStatsLine) } icon: { Image("NodeIPFS") }
                }
                Button(action: onSwarmNode) {
                    Label { Text(swarmStatsLine) } icon: { Image("NodeSwarm") }
                }
                Button(action: onLightClient) {
                    Label { Text(gnosisStatsLine) } icon: { Image("NodeGnosis") }
                }
                Button(action: onLightClient) {
                    Label { Text(ethereumStatsLine) } icon: { Image("NodeEthereum") }
                }
            }
        } label: {
            NodeStatusIcon(
                swarm: swarmSegment,
                ipfs: ipfsSegment,
                ethereum: ethereumSegment,
                gnosis: gnosisSegment
            )
        }
        .modifier(NativeGlassMenuStyle())
    }
}

/// iOS 26+ uses the system glass button style + circle border shape so
/// the Menu morphs natively into the popover with no rectangular flash.
/// On older iOS, falls back to the cross-version `.glassPill()` capsule.
private struct NativeGlassMenuStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
        } else {
            content
                .frame(width: 50, height: 50)
                .glassPill()
        }
    }
}
