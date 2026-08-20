import SwiftUI
import SwarmKit
import IPFSKit
import MyotisKit
import RadicleKit

/// Display state of one segment in the node indicator. The mapping from
/// each node's richer status is a pure function so the decision tables
/// are unit-testable without views.
enum NodeSegmentState: Equatable {
    /// Enabled but not running — neutral absence, not alarm.
    /// (Settings-disabled nodes don't get a segment at all.)
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

    /// Embedded Radicle node — same shape as Swarm: running without a
    /// peer can neither fetch nor publish, so it reads as warming.
    static func fromRadicle(_ status: RadicleStatus, peerCount: Int) -> NodeSegmentState {
        switch status {
        case .idle, .stopping, .stopped: .off
        case .failed: .failed
        case .starting: .warming
        case .running: peerCount == 0 ? .warming : .healthy
        }
    }
}

/// Ambient node-health label for the menu pill. Replaces the ellipsis so
/// the user always knows their node states without opening a node sheet.
///
/// Visual encoding: one ring of equal arc segments — one per ENABLED
/// node, in menu order (Swarm, IPFS, Radicle, Ethereum, Gnosis) starting
/// at 12 o'clock — each colored by that node's `NodeSegmentState`
/// (gray = off · red = failed · orange = warming · green = healthy).
/// Settings-disabled nodes contribute no segment; the ring redistributes
/// among the rest, so the segment count itself shows how many networks
/// are switched on. All disabled → a single neutral gray ring.
struct NodeStatusIcon: View {
    struct Segment: Equatable {
        let name: String
        let state: NodeSegmentState
    }

    let segments: [Segment]

    var body: some View {
        ZStack {
            if segments.isEmpty {
                ring(from: 0, to: 1, color: NodeSegmentState.off.color)
            } else {
                ForEach(Array(segments.enumerated()), id: \.element.name) { index, segment in
                    ring(
                        from: CGFloat(index) / CGFloat(segments.count) + Self.gap,
                        to: CGFloat(index + 1) / CGFloat(segments.count) - Self.gap,
                        color: segment.state.color
                    )
                }
            }
        }
        // trim runs clockwise from 3 o'clock; rotate so the first
        // segment starts at 12.
        .rotationEffect(.degrees(-90))
        .frame(width: 22, height: 22)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Gap on each side of a segment boundary, in trim units. At 22pt a
    /// 0.03 gap keeps up to five segments reading as distinct things.
    private static let gap: CGFloat = 0.03

    private func ring(from: CGFloat, to: CGFloat, color: Color) -> some View {
        Circle()
            .trim(from: from, to: max(from, to))
            .stroke(color, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            .frame(width: 16, height: 16)
    }

    private var accessibilityLabel: String {
        guard !segments.isEmpty else { return "All nodes disabled." }
        return segments
            .map { "\($0.name) \(describe($0.state))." }
            .joined(separator: " ")
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
            NodeStatusIcon(segments: [
                .init(name: "Swarm", state: .healthy),
                .init(name: "IPFS", state: .healthy),
                .init(name: "Radicle", state: .healthy),
                .init(name: "Ethereum", state: .warming),
                .init(name: "Gnosis", state: .warming),
            ])
            Text("all five").font(.caption2)
        }
        VStack(spacing: 4) {
            NodeStatusIcon(segments: [
                .init(name: "Swarm", state: .healthy),
                .init(name: "Radicle", state: .warming),
                .init(name: "Ethereum", state: .failed),
            ])
            Text("three on").font(.caption2)
        }
        VStack(spacing: 4) {
            NodeStatusIcon(segments: [
                .init(name: "Swarm", state: .off)
            ])
            Text("one on").font(.caption2)
        }
        VStack(spacing: 4) {
            NodeStatusIcon(segments: [])
            Text("all disabled").font(.caption2)
        }
    }
    .padding()
}
