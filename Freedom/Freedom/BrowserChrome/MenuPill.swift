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
struct MenuPill: View, Equatable {
    /// Enabled nodes only, menu order — the label ring redistributes
    /// among them (see NodeStatusIcon).
    let statusSegments: [NodeStatusIcon.Segment]
    /// Live one-line summary for the Nodes row ("4 of 5 online · 73
    /// peers"). A single row's text refreshing is harmless — unlike the
    /// former nodes submenu, there is no expansion state to reset.
    let nodesSummaryLine: String

    let isURLBookmarked: Bool
    let canBookmark: Bool
    let shareURL: URL?

    let onBookmarkToggle: () -> Void
    let onTabs: () -> Void
    let onNewTab: () -> Void
    let onWallet: () -> Void
    let onNodes: () -> Void
    let onSettings: () -> Void

    /// Data-only equality: the closures defeat SwiftUI's automatic
    /// diffing, so without this the pill re-evaluates on EVERY
    /// ContentView update (each poll tick), and every re-evaluation
    /// rebuilds the UIKit menu — visible as a periodic "update rhythm"
    /// and, worse, a rebuild resets the nodes submenu to collapsed
    /// while it's open. Comparing just the displayed data means the
    /// menu only rebuilds when something visible actually changed.
    /// (Pair with `.equatable()` at the use site.)
    static func == (lhs: MenuPill, rhs: MenuPill) -> Bool {
        lhs.statusSegments == rhs.statusSegments
            && lhs.nodesSummaryLine == rhs.nodesSummaryLine
            && lhs.isURLBookmarked == rhs.isURLBookmarked
            && lhs.canBookmark == rhs.canBookmark
            && lhs.shareURL == rhs.shareURL
    }

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

            // Top-most section: ONE Nodes row. The per-node entries and
            // their live peer counts live in the NodesDrawer sheet —
            // menus are UIKit snapshots, so anything that ticks in here
            // forces rebuilds (the former nodes submenu re-collapsed
            // itself on every peer-count change). The summary line may
            // refresh in place; a lone row has no state to lose.
            Section {
                // Text+Text+Image directly in the label builder — the
                // documented recipe for a menu row title + subtitle +
                // icon. Wrapping them in a Label collapses the subtitle.
                Button(action: onNodes) {
                    Text("Nodes")
                    Text(nodesSummaryLine)
                    Image(systemName: "network")
                }
            }
        } label: {
            NodeStatusIcon(segments: statusSegments)
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
