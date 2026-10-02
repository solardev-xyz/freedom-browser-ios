import BigInt
import SwarmKit
import SwiftUI
import UIKit

/// Container view for the embedded Swarm node — status, wallet,
/// chequebook, stamps. Diagnostic logs hang off an unobtrusive footer
/// link so the 99% of users who don't care never see them.
@MainActor
struct NodeHomeView: View {
    @Environment(SwarmNode.self) private var swarm
    @Environment(BeeIdentityCoordinator.self) private var beeIdentity
    @Environment(BeeReadiness.self) private var beeReadiness
    @Environment(SettingsStore.self) private var settings
    @Environment(StampService.self) private var stampService
    @Environment(BeeWalletInfo.self) private var beeWallet
    @Environment(SwarmPublishHistoryStore.self) private var publishHistoryStore
    @Environment(StorageFundingController.self) private var funding

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isExternal { externalCard } else { enableCard }
                if settings.swarmNodeEnabled || isExternal {
                    // CTA whenever the user doesn't have a usable stamp —
                    // covers fresh ultralight users, mid-sync, and the
                    // light+ready+no-stamps gap. The setup is only "done"
                    // once the user has a usable stamp (step 4 of the
                    // checklist). Node-side funding is a C API on the
                    // embedded node: an external node buys its own stamps.
                    if !stampService.hasUsableStamps, !isExternal {
                        publishSetupCTA
                    }
                    statusCard
                    nodeWalletCard
                    // The chequebook (and the settlement it backs) is
                    // readable once the gateway's chain init has run.
                    if beeReadiness.state == .ready {
                        chequebookCard
                    }
                    // Stamp rows appear once the node holds a batch.
                    // Pre-setup users use the publish-setup CTA above and
                    // never see a half-disabled "stamps" row.
                    if !stampService.stamps.isEmpty {
                        publishRow
                        stampsRow
                        publishHistoryRow
                    }
                    if !isExternal { logsLink }
                }
            }
            .padding(20)
        }
    }

    private var isExternal: Bool { settings.usesExternalSwarmEndpoint }

    /// Settings → Swarm points at an external node: no embedded node to
    /// enable; everything below reads that node's API.
    private var externalCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("External node").font(.headline)
            Text(settings.swarmExternalEndpointURL?.absoluteString ?? settings.swarmExternalEndpoint)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Text("Its identity, storage and stamps are that node's. Change it under Settings → Swarm.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Top-level enable/disable for the Swarm node. When off the rest
    /// of the sheet is hidden — there's nothing meaningful to show
    /// (no peers, no chequebook, no stamps). Toggle ON kicks off a
    /// runtime boot using the same flow as app launch.
    private var enableCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Enable")
                    .font(.headline)
                Text("Run the embedded Swarm (bee) node")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Enable", isOn: enableBinding)
                .labelsHidden()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var enableBinding: Binding<Bool> {
        Binding(
            get: { settings.swarmNodeEnabled },
            set: { newValue in
                settings.swarmNodeEnabled = newValue
                if newValue {
                    Task { await SwarmRuntime.enable(swarm: swarm, settings: settings) }
                } else {
                    swarm.stop()
                }
            }
        )
    }

    /// Pushes onto the existing NodeSheet NavigationStack — no second
    /// modal layer.
    private var publishSetupCTA: some View {
        NavRowCard(
            icon: "sparkles", title: "Setup Swarm publishing",
            subtitle: "Buy storage to start publishing",
            background: Color.accentColor.opacity(0.12)
        ) {
            PublishSetupView()
        }
    }

    // MARK: - Cards

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Status").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Circle()
                    .frame(width: 10, height: 10)
                    .foregroundStyle(isExternal ? (beeReadiness.state == .ready ? Color.green : Color.orange) : swarm.status.color)
                Text(isExternal ? "external" : swarm.status.rawValue)
                    .font(.headline)
                    .monospaced()
                Spacer()
                if !isExternal {
                    Text("\(swarm.peerCount) peers")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Divider().opacity(0.3)
            nodeStateRow
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

    private var nodeWalletCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Node wallet").font(.caption).foregroundStyle(.secondary)
            balanceRow(label: "xDAI", value: beeWallet.nodeXdai, decimals: 18)
            balanceRow(label: "xBZZ", value: beeWallet.nodeXbzz, decimals: 16)
            if !displayAddress.isEmpty {
                CopyableAddressRow(address: displayAddress)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var chequebookCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chequebook").font(.caption).foregroundStyle(.secondary)
            balanceRow(label: "xBZZ", value: beeWallet.chequebookXbzz, decimals: 16)
            if let addr = beeReadiness.chequebookAddress {
                CopyableAddressRow(address: addr)
            }
            if !isExternal { settlementDepositRow }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: beeReadiness.chequebookAddress ?? "") { if !isExternal { await funding.refreshDeposit() } }
    }

    /// The settlement deposit backs the cheques the node signs for
    /// bandwidth. Installs from before node-side funding may run with
    /// an empty one; the node tops it up from xDAI it holds.
    @ViewBuilder private var settlementDepositRow: some View {
        if let deposit = funding.deposit, !deposit.enabled, !stampService.stamps.isEmpty {
            // Batches but no chequebook (a deploy that ran out of gas,
            // a reinstall whose old chequebook can't be rediscovered):
            // gateway start never deploys, so offer it here.
            VStack(alignment: .leading, spacing: 8) {
                Text("Settlement is off: your node can't pay peers for bandwidth yet.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await funding.setUpSettlement() }
                } label: {
                    Label(
                        funding.isSettingUpSettlement ? "Setting up…" : "Set up settlement",
                        systemImage: funding.isSettingUpSettlement ? "hourglass" : "checkmark.seal.fill"
                    )
                }
                .buttonStyle(PrimaryActionStyle(isEnabled: !funding.isSettingUpSettlement))
                .disabled(funding.isSettingUpSettlement)
                if let error = funding.depositError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        } else if let deposit = funding.deposit, deposit.enabled {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Settlement deposit").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(deposit.depositBzz) / \(deposit.targetBzz) xBZZ")
                        .font(.callout).monospacedDigit()
                }
                if deposit.needsTopUp {
                    if deposit.sufficientFunds {
                        Button {
                            Task { await funding.topUpDeposit() }
                        } label: {
                            Label(
                                funding.isToppingUpDeposit ? "Topping up…" : "Top up from node wallet",
                                systemImage: funding.isToppingUpDeposit ? "hourglass" : "arrow.up.circle.fill"
                            )
                        }
                        .buttonStyle(PrimaryActionStyle(isEnabled: !funding.isToppingUpDeposit))
                        .disabled(funding.isToppingUpDeposit)
                    } else {
                        Text("Send \(StoragePayment.roundedUpXdai(deposit.xdaiToSendDisplay)) xDAI to your node wallet to fund the deposit.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = funding.depositError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
    }

    /// Desktop's `freedom://publish`: publish a file, folder or text
    /// from this device.
    private var publishRow: some View {
        NavRowCard(
            icon: "square.and.arrow.up", title: "Publish on Swarm",
            subtitle: "A file, a folder or text from this device",
            background: Color.accentColor.opacity(0.12)
        ) {
            SwarmPublishView()
        }
    }

    /// `StampsView` itself decides whether to show the empty state or
    /// the batch list — the row's job is just navigation + count copy.
    private var stampsRow: some View {
        NavRowCard(
            icon: "shippingbox.fill", title: "Storage stamps",
            subtitle: stampsRowSubtitle
        ) {
            StampsView()
        }
    }

    private var stampsRowSubtitle: String {
        let count = stampService.stamps.count
        if count == 0 { return "Buy a stamp to start publishing" }
        let usable = stampService.stamps.filter(\.usable).count
        return "\(count) batch\(count == 1 ? "" : "es") · \(usable) usable"
    }

    private var publishHistoryRow: some View {
        NavRowCard(
            icon: "tray.full", title: "Publish history",
            subtitle: publishHistoryRowSubtitle
        ) {
            SwarmPublishHistoryView()
        }
    }

    private var publishHistoryRowSubtitle: String {
        let count = publishHistoryStore.entries.count
        if count == 0 { return "Nothing published yet" }
        return "\(count) entr\(count == 1 ? "y" : "ies")"
    }

    /// Diagnostic surface — tertiary text at the bottom of the sheet so
    /// it's findable for bug reports but invisible to anyone scanning.
    /// `.buttonStyle(.plain)` keeps the label's `.tertiary` foreground
    /// from being overridden by NavigationLink's accent chrome.
    private var logsLink: some View {
        NavigationLink {
            NodeLogView()
        } label: {
            Text("View logs")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 8)
    }

    // MARK: - Helpers

    // bee-lite's `0x` prefix isn't contractual; normalise.
    private var displayAddress: String { Hex.prefixed(swarm.walletAddress) }

    /// Readiness in one line. The address bar shows the same suffix at
    /// all times; this row mirrors it inside the node sheet.
    private var nodeStateRow: some View {
        row(label: "Node", value: nodeStateValue)
    }

    private var nodeStateValue: String {
        switch beeReadiness.state {
        case .ready: return "ready"
        case .startingUp: return "starting up"
        case .syncingPostage(let percent, _, _): return "syncing \(percent)%"
        case .initializing: return isExternal ? "connecting" : "starting"
        }
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout)
        }
    }

    /// "Token name → numeric value" row used by both wallet + chequebook
    /// cards. Renders a placeholder while bee hasn't reported a value
    /// yet so the row's vertical rhythm doesn't jump on first poll.
    private func balanceRow(label: String, value: BigUInt?, decimals: Int) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            if let value {
                Text(BalanceFormatter.formatAmount(
                    wei: value, decimals: decimals, maxFractionDigits: 4
                ))
                .font(.callout)
                .monospacedDigit()
            } else {
                Text("—").font(.callout).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Icon + title/subtitle + chevron card pushing onto the existing
/// NodeSheet NavigationStack. Three callers (`publishSetupCTA`,
/// `stampsRow`, `publishHistoryRow`) had identical chrome differing
/// only in copy + background tint.
@MainActor
private struct NavRowCard<Destination: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    var background: Color = Color(.secondarySystemBackground)
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout).fontWeight(.semibold)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

/// Tap-to-copy row with shortened address display. The full address
/// goes on the pasteboard; the shortened form is just the visual.
@MainActor
private struct CopyableAddressRow: View {
    let address: String
    @State private var didCopy: Bool = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 8) {
                Text(address.shortenedHex())
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.footnote)
                    .foregroundStyle(didCopy ? Color.green : .secondary)
                if didCopy {
                    Text("Copied")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func copy() {
        UIPasteboard.general.string = address
        withAnimation { didCopy = true }
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            withAnimation { didCopy = false }
        }
    }
}
