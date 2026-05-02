import SwiftUI
import SwarmKit
import IPFSKit

/// Ambient node-health label for the menu pill. Replaces the ellipsis so
/// the user always knows their node states without opening either node
/// sheet.
///
/// Visual encoding:
///   - Center dot color: Swarm status — red = off · orange = warming up · green = running with ≥1 peer
///   - Arcs above the dot (Swarm peer-count tiers, colored to match the dot):
///       0 arcs · <10 peers
///       1 arc  · 10–99 peers
///       2 arcs · 100+ peers
///   - Arcs below the dot (IPFS peer-count tiers, colored independently
///     by IPFS status): same tiers, mirrored. Lets the user read
///     reachability of both nodes at a glance without opening the menu.
struct NodeStatusIcon: View {
    let swarmStatus: SwarmStatus
    let swarmPeerCount: Int
    let ipfsStatus: IPFSStatus
    let ipfsPeerCount: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(swarmColor)
                .frame(width: 5, height: 5)
            // Swarm: arcs above
            if swarmArcCount >= 1 { arc(diameter: 12, color: swarmColor, above: true) }
            if swarmArcCount >= 2 { arc(diameter: 18, color: swarmColor, above: true) }
            // IPFS: arcs below
            if ipfsArcCount >= 1  { arc(diameter: 12, color: ipfsColor,  above: false) }
            if ipfsArcCount >= 2  { arc(diameter: 18, color: ipfsColor,  above: false) }
        }
        .frame(width: 22, height: 22)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Trim windows are 0.30 wide so the visible arc spans the same
    /// angular range above and below. `above: true` traces the upper
    /// hemisphere; `above: false` traces the lower (mirror across the
    /// horizontal axis).
    private func arc(diameter: CGFloat, color: Color, above: Bool) -> some View {
        Circle()
            .trim(from: above ? 0.6 : 0.1, to: above ? 0.9 : 0.4)
            .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: diameter, height: diameter)
    }

    private var swarmColor: Color {
        switch swarmStatus {
        case .idle, .stopping, .stopped, .failed: return .red
        case .starting:                            return .orange
        case .running:                             return swarmPeerCount == 0 ? .orange : .green
        }
    }

    private var ipfsColor: Color {
        switch ipfsStatus {
        case .idle, .stopping, .stopped, .failed: return .red
        case .starting:                            return .orange
        case .running:                             return ipfsPeerCount == 0 ? .orange : .green
        }
    }

    private var swarmArcCount: Int { arcCount(running: swarmStatus == .running, peers: swarmPeerCount) }
    private var ipfsArcCount: Int  { arcCount(running: ipfsStatus  == .running, peers: ipfsPeerCount) }

    private func arcCount(running: Bool, peers: Int) -> Int {
        guard running else { return 0 }
        if peers >= 100 { return 2 }
        if peers >= 10  { return 1 }
        return 0
    }

    private var accessibilityLabel: String {
        "Swarm: \(describe(status: swarmStatus.rawValue, peers: swarmPeerCount, isRunning: swarmStatus == .running)). " +
        "IPFS: \(describe(status: ipfsStatus.rawValue, peers: ipfsPeerCount, isRunning: ipfsStatus == .running))."
    }

    private func describe(status: String, peers: Int, isRunning: Bool) -> String {
        guard isRunning else { return status }
        return peers == 0 ? "running, connecting" : "running, \(peers) peer\(peers == 1 ? "" : "s")"
    }
}

#Preview {
    HStack(spacing: 24) {
        VStack(spacing: 4) {
            NodeStatusIcon(swarmStatus: .stopped, swarmPeerCount: 0, ipfsStatus: .stopped, ipfsPeerCount: 0)
            Text("both off").font(.caption2)
        }
        VStack(spacing: 4) {
            NodeStatusIcon(swarmStatus: .running, swarmPeerCount: 5, ipfsStatus: .stopped, ipfsPeerCount: 0)
            Text("S 5 / I off").font(.caption2)
        }
        VStack(spacing: 4) {
            NodeStatusIcon(swarmStatus: .running, swarmPeerCount: 50, ipfsStatus: .running, ipfsPeerCount: 5)
            Text("S 50 / I 5").font(.caption2)
        }
        VStack(spacing: 4) {
            NodeStatusIcon(swarmStatus: .running, swarmPeerCount: 200, ipfsStatus: .running, ipfsPeerCount: 50)
            Text("S 200 / I 50").font(.caption2)
        }
        VStack(spacing: 4) {
            NodeStatusIcon(swarmStatus: .running, swarmPeerCount: 200, ipfsStatus: .running, ipfsPeerCount: 200)
            Text("both 200").font(.caption2)
        }
    }
    .padding()
}
