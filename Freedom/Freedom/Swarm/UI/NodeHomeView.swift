import SwarmKit
import SwiftUI

/// Container view for the embedded Swarm node — status, wallet, recent
/// activity. Future surfaces (upgrade flow, stamp management) hang off
/// the same NavigationStack via push.
@MainActor
struct NodeHomeView: View {
    @Environment(SwarmNode.self) private var swarm
    @Environment(BeeIdentityCoordinator.self) private var beeIdentity
    @Environment(BeeReadiness.self) private var beeReadiness
    @Environment(SettingsStore.self) private var settings
    @Environment(StampService.self) private var stampService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // CTA whenever the user doesn't have a usable stamp —
                // covers fresh ultralight users, mid-sync, and the
                // light+ready+no-stamps gap. The setup is only "done"
                // once the user has a usable stamp (step 4 of the
                // checklist).
                if !stampService.hasUsableStamps {
                    publishSetupCTA
                }
                statusCard
                walletCard
                // Stamps row appears once the user has crossed `.ready`
                // at least once — same gate as the inline mode toggle.
                // Pre-setup users use the publish-setup CTA above and
                // never see a half-disabled "stamps" row.
                if settings.hasCompletedPublishSetup {
                    stampsRow
                }
                logCard
            }
            .padding(20)
        }
    }

    /// Pushes onto the existing NodeSheet NavigationStack — no second
    /// modal layer.
    private var publishSetupCTA: some View {
        NavigationLink {
            PublishSetupView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setup Swarm publishing").font(.callout).fontWeight(.semibold)
                    Text("Upgrade your node to start publishing")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.accentColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
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
            modeRow
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

    /// Pushes onto the existing NodeSheet NavigationStack, same shape
    /// as `publishSetupCTA`. `StampsView` itself decides whether to
    /// show the empty state or the batch list.
    private var stampsRow: some View {
        NavigationLink {
            StampsView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.fill").font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Storage stamps").font(.callout).fontWeight(.semibold)
                    Text(stampsRowSubtitle)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var stampsRowSubtitle: String {
        let count = stampService.stamps.count
        if count == 0 { return "Buy a stamp to start publishing" }
        let usable = stampService.stamps.filter(\.usable).count
        return "\(count) batch\(count == 1 ? "" : "es") · \(usable) usable"
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

    /// Mode row — value becomes an inline `Menu` when toggling is safe
    /// (i.e. the user has reached `.ready` at least once, so statestore
    /// is known to carry the chequebook reference). Pre-setup users
    /// see a plain string and use the `publishSetupCTA` instead.
    @ViewBuilder private var modeRow: some View {
        HStack {
            Text("Mode").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if settings.hasCompletedPublishSetup {
                Menu {
                    Button("Light") { switchMode(to: .light) }
                        .disabled(settings.beeNodeMode == .light)
                    Button("Ultralight") { switchMode(to: .ultraLight) }
                        .disabled(settings.beeNodeMode == .ultraLight)
                } label: {
                    HStack(spacing: 4) {
                        Text(modeRowValue).font(.callout)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(modeRowValue).font(.callout)
            }
        }
    }

    /// Human-readable mode label. In light mode, append the readiness
    /// state — chequebook deploy / sync %. ContentView's status bar
    /// shows the same suffix at all times; this row mirrors it inside
    /// the node sheet so users don't have to check both surfaces.
    private var modeRowValue: String {
        switch (settings.beeNodeMode, beeReadiness.state) {
        case (.ultraLight, _): return "Ultralight"
        case (.light, .ready): return "Light · ready"
        case (.light, .startingUp): return "Light · starting up"
        case (.light, .syncingPostage(let percent, _, _)):
            return "Light · syncing \(percent)%"
        case (.light, .initializing): return "Light · starting"
        case (.light, .browsingOnly): return "Light"
        }
    }

    private func switchMode(to newMode: BeeNodeMode) {
        beeIdentity.switchMode(to: newMode, swarm: swarm)
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout)
        }
    }
}
