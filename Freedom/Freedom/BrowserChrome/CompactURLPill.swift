import SwiftUI

/// Scrolled-down chrome state: TrustShield + host, content-sized.
struct CompactURLPill: View {
    let trust: ENSTrust?
    let displayURL: URL?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if let trust {
                    TrustShield(trust: trust)
                        .frame(width: 22, height: 22)
                }
                Text(displayURL?.hostOrAbsolute ?? URLPill.placeholder)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.subheadline)
                    .foregroundStyle(displayURL == nil ? .secondary : .primary)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassPill()
    }
}
