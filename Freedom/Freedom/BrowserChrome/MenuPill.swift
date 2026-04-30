import SwiftUI
import SwarmKit

/// Catch-all menu pill. The label is the ambient `NodeStatusIcon` (red
/// dot when off, green with arcs by peer count) instead of an ellipsis.
struct MenuPill: View {
    let nodeStatus: SwarmStatus
    let peerCount: Int

    let isURLBookmarked: Bool
    let canBookmark: Bool
    let shareURL: URL?

    let onBookmarkToggle: () -> Void
    let onTabs: () -> Void
    let onWallet: () -> Void
    let onNode: () -> Void
    let onBookmarks: () -> Void
    let onHistory: () -> Void
    let onSettings: () -> Void

    var body: some View {
        Menu {
            Button(action: onBookmarkToggle) {
                Label(
                    isURLBookmarked ? "Remove bookmark" : "Add bookmark",
                    systemImage: isURLBookmarked ? "star.fill" : "star"
                )
            }
            .disabled(!canBookmark)

            if let url = shareURL {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }

            Divider()

            Button(action: onTabs) {
                Label("Tabs", systemImage: "square.on.square")
            }
            Button(action: onWallet) {
                Label("Wallet", systemImage: "creditcard.fill")
            }
            Button(action: onNode) {
                Label("Node", systemImage: "circle.hexagongrid.fill")
            }

            Divider()

            Button(action: onBookmarks) {
                Label("Bookmarks", systemImage: "book")
            }
            Button(action: onHistory) {
                Label("History", systemImage: "clock")
            }

            Divider()

            Button(action: onSettings) {
                Label("Settings", systemImage: "gear")
            }
        } label: {
            NodeStatusIcon(status: nodeStatus, peerCount: peerCount)
                .frame(width: 44, height: 44)
        }
        .glassPill()
    }
}
