import SwarmKit
import SwiftUI

/// Container view for the embedded Swarm node — status, wallet, recent
/// activity. Future surfaces (upgrade flow, stamp management) hang off
/// the same NavigationStack via push.
@MainActor
struct NodeHomeView: View {
    @Environment(SwarmNode.self) private var swarm
    @Environment(BeeIdentityCoordinator.self) private var beeIdentity

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusCard
                walletCard
                logCard
            }
            .padding(20)
        }
    }

    // MARK: - Cards

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Status").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Circle()
                    .frame(width: 10, height: 10)
                    .foregroundStyle(swarm.status.color)
                Text(swarm.status.rawValue)
                    .font(.headline)
                    .monospaced()
                Spacer()
                Text("\(swarm.peerCount) peers")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Divider().opacity(0.3)
            row(label: "Mode", value: "Ultralight")
            if beeIdentity.status == .swapping {
                Divider().opacity(0.3)
                row(label: "Identity", value: "Updating…")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var walletCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Node wallet").font(.caption).foregroundStyle(.secondary)
            if displayAddress.isEmpty {
                Text("Not yet available")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                AddressPill(address: displayAddress)
            }
        }
    }

    @ViewBuilder private var logCard: some View {
        if !swarm.log.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent activity").font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    // 12 ≈ one restart cycle, fits without scrolling.
                    ForEach(Array(swarm.log.suffix(12).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Helpers

    // bee-lite's `0x` prefix isn't contractual; normalise.
    private var displayAddress: String { Hex.prefixed(swarm.walletAddress) }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout)
        }
    }
}
