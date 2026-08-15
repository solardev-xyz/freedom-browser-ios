import SwiftUI
import SwarmKit
import IPFSKit
import MyotisKit

/// Display state of one segment in the node indicator. The mapping from
/// each node's richer status is a pure function so the decision tables
/// are unit-testable without views.
enum NodeSegmentState: Equatable {
    /// Deliberately disabled / not running — neutral absence, not alarm.
    case off
    /// Start failure, ABI mismatch — the only state that renders red.
    case failed
    /// Coming up: starting, syncing, connecting, finding state peers.
    case warming
    /// Fully serving (running with peers / verified reads available).
    case healthy

    var color: Color {
        switch self {
        case .off: .gray.opacity(0.45)
        case .failed: .red
        case .warming: .orange
        case .healthy: .green
        }
    }

    static func fromSwarm(_ status: SwarmStatus, peerCount: Int) -> NodeSegmentState {
        switch status {
        case .idle, .stopping, .stopped: .off
        case .failed: .failed
        case .starting: .warming
        case .running: peerCount == 0 ? .warming : .healthy
        }
    }

    static func fromIpfs(_ status: IPFSStatus) -> NodeSegmentState {
        switch status {
        case .idle, .stopping, .stopped: .off
        case .failed: .failed
        case .starting: .warming
        case .running: .healthy
        }
    }

    /// One light-client chain. `healthy` means verified reads are
    /// actually servable (SYNCED + snap peer), not merely beacon-synced.
    static func fromMyotisChain(
        _ status: MyotisStatus,
        chain: MyotisChainStatus?
    ) -> NodeSegmentState {
        switch status {
        case .idle, .stopping, .stopped: return .off
        case .failed: return .failed
        case .starting: return .warming
        case .running: return (chain?.ready ?? false) ? .healthy : .warming
        }
    }
}

/// Ambient node-health label for the menu pill. Replaces the ellipsis so
/// the user always knows their node states without opening a node sheet.
///
/// Visual encoding: one ring of four quarter-arc segments with gaps at
/// 12/3/6/9 o'clock, each colored by that node's `NodeSegmentState`
/// (gray = off · red = failed · orange = warming · green = healthy):
///
///   top-left  Swarm        top-right    IPFS
///   bottom-left Ethereum   bottom-right Gnosis
///
/// Content nodes across the top, chain verification across the bottom.
struct NodeStatusIcon: View {
    let swarm: NodeSegmentState
    let ipfs: NodeSegmentState
    let ethereum: NodeSegmentState
    let gnosis: NodeSegmentState

    var body: some View {
        ZStack {
            segment(topLeft, color: swarm.color)
            segment(topRight, color: ipfs.color)
            segment(bottomLeft, color: ethereum.color)
            segment(bottomRight, color: gnosis.color)
        }
        .frame(width: 22, height: 22)
        .accessibilityLabel(accessibilityLabel)
    }

    // Circle().trim starts at 3 o'clock and runs clockwise: 0.25 = 6,
    // 0.5 = 9, 0.75 = 12 o'clock. Each quadrant keeps a 0.03 gap on
    // both sides so the four segments read as four things at 22pt.
    private var bottomRight: (CGFloat, CGFloat) { (0.03, 0.22) }
    private var bottomLeft: (CGFloat, CGFloat) { (0.28, 0.47) }
    private var topLeft: (CGFloat, CGFloat) { (0.53, 0.72) }
    private var topRight: (CGFloat, CGFloat) { (0.78, 0.97) }

    private func segment(_ range: (CGFloat, CGFloat), color: Color) -> some View {
        Circle()
            .trim(from: range.0, to: range.1)
            .stroke(color, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            .frame(width: 16, height: 16)
    }

    private var accessibilityLabel: String {
        "Swarm \(describe(swarm)). IPFS \(describe(ipfs)). "
            + "Ethereum light client \(describe(ethereum)). Gnosis light client \(describe(gnosis))."
    }

    private func describe(_ state: NodeSegmentState) -> String {
        switch state {
        case .off: "off"
        case .failed: "failed"
        case .warming: "starting"
        case .healthy: "healthy"
        }
    }
}

#Preview {
    HStack(spacing: 24) {
        VStack(spacing: 4) {
            NodeStatusIcon(swarm: .off, ipfs: .off, ethereum: .off, gnosis: .off)
            Text("all off").font(.caption2)
        }
        VStack(spacing: 4) {
            NodeStatusIcon(swarm: .healthy, ipfs: .healthy, ethereum: .warming, gnosis: .warming)
            Text("chains syncing").font(.caption2)
        }
        VStack(spacing: 4) {
            NodeStatusIcon(swarm: .healthy, ipfs: .healthy, ethereum: .healthy, gnosis: .healthy)
            Text("all green").font(.caption2)
        }
        VStack(spacing: 4) {
            NodeStatusIcon(swarm: .warming, ipfs: .failed, ethereum: .healthy, gnosis: .off)
            Text("mixed").font(.caption2)
        }
    }
    .padding()
}
