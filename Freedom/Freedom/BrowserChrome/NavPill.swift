import SwiftUI

/// Back/forward pill. Forward only appears when there's somewhere to go,
/// matching Safari — a fresh tab shows just the back chevron (disabled).
struct NavPill: View {
    let canGoBack: Bool
    let canGoForward: Bool
    let onBack: () -> Void
    let onForward: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onBack) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 50, height: 50)
            }
            .disabled(!canGoBack)
            if canGoForward {
                Button(action: onForward) {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 50, height: 50)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        // Default Button tint is the accent color (blue). The chevrons
        // read better as standard label color so they don't fight with
        // the URL pill's neutral text.
        .tint(.primary)
        .glassPill()
        .animation(.spring(duration: 0.35), value: canGoForward)
    }
}
