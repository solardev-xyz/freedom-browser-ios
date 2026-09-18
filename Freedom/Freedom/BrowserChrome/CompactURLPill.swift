import SwiftUI

/// Scrolled-down chrome state: TrustShield + host, content-sized.
struct CompactURLPill: View {
    let trust: ENSTrust?
    let displayURL: URL?
    var onchain: OnchainAppProvenance? = nil
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if let trust {
                    TrustShield(trust: trust, onchain: onchain)
                        .frame(width: 22, height: 22)
                }
                Text(displayURL?.hostOrAbsolute ?? URLPill.placeholder)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.subheadline)
                    .foregroundStyle(displayURL == nil ? .secondary : .primary)
            }
            .padding(.horizontal, 16)
            .frame(height: 38)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassPill()
    }
}
