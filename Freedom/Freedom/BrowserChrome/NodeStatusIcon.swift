import SwiftUI
import SwarmKit

/// Ambient node-health label for the menu pill. Replaces the ellipsis so
/// the user always knows their node state without opening the Node sheet.
///
/// Visual encoding:
///   - Color: red = off · orange = warming up · green = running with ≥1 peer
///   - Arcs above the dot:
///       0 arcs · <10 peers
///       1 arc  · 10-99 peers
///       2 arcs · 100+ peers
struct NodeStatusIcon: View {
    let status: SwarmStatus
    let peerCount: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            if arcCount >= 1 {
                arc(diameter: 12)
            }
            if arcCount >= 2 {
                arc(diameter: 18)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityLabel(accessibilityLabel)
    }

    private func arc(diameter: CGFloat) -> some View {
        Circle()
            .trim(from: 0.6, to: 0.9)
            .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: diameter, height: diameter)
    }

    private var color: Color {
        switch status {
        case .idle, .stopping, .stopped, .failed: return .red
        case .starting:                            return .orange
        case .running:                             return peerCount == 0 ? .orange : .green
        }
    }

    private var arcCount: Int {
        guard status == .running else { return 0 }
        if peerCount >= 100 { return 2 }
        if peerCount >= 10  { return 1 }
        return 0
    }

    private var accessibilityLabel: String {
        switch status {
        case .idle, .stopping, .stopped, .failed:
            return "Node off"
        case .starting:
            return "Node starting"
        case .running:
            return peerCount == 0
                ? "Node running, connecting to peers"
                : "Node running, \(peerCount) peer\(peerCount == 1 ? "" : "s")"
        }
    }
}

#Preview {
    HStack(spacing: 24) {
        VStack(spacing: 4) { NodeStatusIcon(status: .stopped, peerCount: 0); Text("off").font(.caption2) }
        VStack(spacing: 4) { NodeStatusIcon(status: .starting, peerCount: 0); Text("starting").font(.caption2) }
        VStack(spacing: 4) { NodeStatusIcon(status: .running, peerCount: 0); Text("0").font(.caption2) }
        VStack(spacing: 4) { NodeStatusIcon(status: .running, peerCount: 5); Text("5").font(.caption2) }
        VStack(spacing: 4) { NodeStatusIcon(status: .running, peerCount: 50); Text("50").font(.caption2) }
        VStack(spacing: 4) { NodeStatusIcon(status: .running, peerCount: 200); Text("200").font(.caption2) }
    }
    .padding()
}
