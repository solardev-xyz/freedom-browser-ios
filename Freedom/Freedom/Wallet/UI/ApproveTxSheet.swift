import BigInt
import SwiftUI
import web3

/// `eth_sendTransaction` approval. Bridge has already estimated fees and
/// composed `SendTransactionDetails`; the sheet just renders + collects
/// the user's tap. WP11 uses tap-to-approve; slide-to-approve is M5.7
/// polish per §8.
@MainActor
struct ApproveTxSheet: View {
    @Environment(Vault.self) private var vault
    @Environment(\.dismiss) private var dismiss

    let approval: ApprovalRequest
    let details: SendTransactionDetails

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ApprovalOriginStrip(origin: approval.origin, caption: "This site wants to send a transaction")
                    switch vault.state {
                    case .empty:
                        Label("Set up a wallet first, then try again.", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                    case .locked:
                        ApprovalUnlockStrip()
                    case .unlocked:
                        unlockedBody
                    }
                }
                .padding(20)
            }
            .navigationTitle("Send transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        approval.decide(.denied)
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder private var unlockedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            recipientCard
            valueCard
            if !details.data.isEmpty {
                dataCard
            }
            feeCard
            Text("Transactions are irreversible once broadcast. Only approve if you recognise the site.")
                .font(.caption)
                .foregroundStyle(.secondary)
            PrimaryActionButton(title: "Approve", systemImage: "checkmark", action: approve)
        }
    }

    private var recipientCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("To").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let recipientName = details.recipientName {
                    // ENS reverse hit — show the name as a primary label,
                    // address pill below stays the canonical cross-check.
                    Text(recipientName).font(.caption.weight(.semibold))
                }
            }
            // Checksum-cased so the user can cross-check addresses against
            // explorers / dapp UIs that already render in EIP-55 form.
            AddressPill(address: details.to.toChecksumAddress())
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var valueCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Amount").font(.caption).foregroundStyle(.secondary)
            Text(BalanceFormatter.format(wei: details.valueWei, on: details.chain))
                .font(.title3.weight(.semibold))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var dataCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Contract call", systemImage: "doc.text.magnifyingglass")
                    .font(.caption)
                Spacer()
                Text(byteCountLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(dataPreview)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var byteCountLabel: String {
        details.data.count == 1 ? "1 byte" : "\(details.data.count) bytes"
    }

    /// First 36 bytes (selector + 1 word) — enough to spot common patterns.
    /// Full ABI decode is M5.7 polish.
    private var dataPreview: String {
        let hex = details.data.web3.hexString
        let cap = 2 + 72  // "0x" + 36 bytes × 2 hex chars
        return hex.count > cap ? String(hex.prefix(cap)) + "…" : hex
    }

    @ViewBuilder private var feeCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Network").font(.caption).foregroundStyle(.secondary)
            Text(details.chain.displayName).font(.callout)
            Divider().padding(.vertical, 2)
            HStack {
                Text(details.valueWei == 0 ? "You pay" : "Estimated fee")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(BalanceFormatter.format(wei: details.quote.maxFeeWei, on: details.chain))
                    .font(.caption.monospaced())
            }
            // Total = value + fee only makes sense when the dapp sent value;
            // for ERC-20 calls (value == 0) "Total = fee" misleads the user
            // into reading the fee as the transfer amount.
            if details.valueWei > 0 {
                HStack {
                    Text("Total").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(BalanceFormatter.format(wei: details.valueWei + details.quote.maxFeeWei, on: details.chain))
                        .font(.callout.weight(.semibold))
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func approve() {
        approval.decide(.approved)
        dismiss()
    }
}
