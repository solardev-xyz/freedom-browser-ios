import BigInt
import SwiftUI

/// Wallet → Activity: every transaction this wallet broadcast, newest
/// first, with its status — desktop's payment history for the kinds
/// iOS signs (wallet sends and dapp sends).
@MainActor
struct WalletActivityView: View {
    @Environment(WalletTransactionHistoryStore.self) private var history
    @Environment(ChainStore.self) private var chainStore
    @State private var showClearConfirmation = false

    var body: some View {
        let entries = history.entries
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if entries.isEmpty {
                    emptyState
                } else {
                    ForEach(entries) { entry in
                        NavigationLink {
                            WalletActivityDetailView(entryID: entry.id)
                        } label: {
                            WalletActivityRow(entry: entry, chain: chainStore.chain(id: entry.chainID))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { showClearConfirmation = true } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .confirmationDialog("Clear activity?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Clear all", role: .destructive) { history.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the local list. Transactions already on chain are unaffected.")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No transactions yet").font(.title3).fontWeight(.semibold)
            Text("Sends from this wallet and transactions dapps ask you to sign show up here with their status.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor
struct WalletActivityRow: View {
    let entry: WalletTransactionRecord
    let chain: Chain?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind == .dappSend ? "globe" : "arrow.up.right")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(WalletActivityFormatting.title(entry))
                    .font(.callout).fontWeight(.medium)
                    .lineLimit(1)
                Text(WalletActivityFormatting.subtitle(entry, chain: chain))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            WalletActivityStatusBadge(status: entry.status)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct WalletActivityStatusBadge: View {
    let status: WalletTransactionStatus

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case .pending: "Pending"
        case .confirmed: "Confirmed"
        case .failed: "Failed"
        }
    }

    private var color: Color {
        switch status {
        case .pending: .orange
        case .confirmed: .green
        case .failed: .red
        }
    }
}

enum WalletActivityFormatting {
    static func title(_ entry: WalletTransactionRecord) -> String {
        let amount = BalanceFormatter.format(wei: entry.amountValue, token: entry.token)
        switch entry.kind {
        case .walletSend: return "Sent \(amount)"
        case .dappSend: return entry.amountValue == 0 ? "Contract call" : "Sent \(amount)"
        }
    }

    static func subtitle(_ entry: WalletTransactionRecord, chain: Chain?) -> String {
        var parts: [String] = []
        if let origin = entry.origin { parts.append(origin) } else { parts.append("to \(abbreviated(entry.toAddress))") }
        if let chain { parts.append(chain.displayName) }
        parts.append(SwarmPublishHistoryFormatting.relativeTime(entry.createdAt))
        return parts.joined(separator: " · ")
    }

    static func abbreviated(_ address: String) -> String {
        guard address.count > 12 else { return address }
        return "\(address.prefix(6))…\(address.suffix(4))"
    }

    /// Gas actually paid, when the receipt carried both fields.
    static func fee(_ entry: WalletTransactionRecord, chain: Chain?) -> String? {
        guard let chain, let used = entry.gasUsed.flatMap(BalanceFormatter.parse(weiHex:)),
              let price = entry.gasPrice.flatMap(BalanceFormatter.parse(weiHex:)) else { return nil }
        return BalanceFormatter.format(wei: used * price, on: chain)
    }
}

/// One transaction: what, where, status, and the explorer link.
@MainActor
struct WalletActivityDetailView: View {
    @Environment(WalletTransactionHistoryStore.self) private var history
    @Environment(ChainStore.self) private var chainStore
    @Environment(TabStore.self) private var tabStore
    @Environment(\.closeWalletSheet) private var closeWalletSheet
    @Environment(\.dismiss) private var dismiss

    let entryID: UUID

    var body: some View {
        if let entry = history.entry(id: entryID) {
            let chain = chainStore.chain(id: entry.chainID)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(WalletActivityFormatting.title(entry)).font(.title3).fontWeight(.semibold)
                        WalletActivityStatusBadge(status: entry.status)
                        if let reason = entry.failureReason {
                            Text(reason).font(.caption).foregroundStyle(.red)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        row("From", entry.fromAddress, mono: true)
                        row("To", entry.toAddress, mono: true)
                        if let origin = entry.origin { row("Requested by", origin) }
                        if let chain { row("Chain", chain.displayName) }
                        row("Transaction", entry.txHash, mono: true)
                        row("Sent", entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                        if let confirmed = entry.confirmedAt {
                            row("Confirmed", confirmed.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let fee = WalletActivityFormatting.fee(entry, chain: chain) { row("Network fee", fee) }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    if let chain {
                        Button {
                            tabStore.open(chain.explorerURL(forTx: entry.txHash), inBackground: false, from: nil)
                            closeWalletSheet()
                        } label: {
                            Label("View on explorer", systemImage: "safari")
                        }
                        .buttonStyle(PrimaryActionStyle())
                    }
                    Button("Copy transaction hash") { UIPasteboard.general.string = entry.txHash }
                        .frame(maxWidth: .infinity)
                    Button("Remove from activity", role: .destructive) {
                        history.delete(id: entry.id)
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(20)
            }
            .navigationTitle("Transaction")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Transaction removed", systemImage: "clock.arrow.circlepath")
        }
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(mono ? .caption.monospaced() : .callout)
                .textSelection(.enabled)
        }
    }
}
