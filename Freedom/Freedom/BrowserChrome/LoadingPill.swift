import SwiftUI

/// Floating glass capsule positioned above the URL pill that surfaces
/// the current loading step. One unified indicator that replaces the
/// previous patchwork of an ENS-resolving banner row, an IPFS-only
/// label inside the URL pill, and WebKit's barely-visible blue
/// progress hairline.
///
/// Driven by `BrowserTab.loadingState`, which folds in:
/// - ENS name resolution ("Resolving foo.eth…")
/// - IPFS gateway phases ("Finding providers", "Fetching from IPFS
///   peers", "Receiving content", …)
///
/// The pill auto-hides when both signals are nil (page rendered /
/// idle).
@MainActor
struct LoadingPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)
            Text(text)
                .font(.footnote)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassPill()
    }
}
