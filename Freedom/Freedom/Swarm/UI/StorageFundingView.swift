import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Buy or extend storage the AntDrive way: pick a plan with an all-in
/// xDAI price, send that xDAI to the node wallet (from the Freedom
/// wallet or any other wallet via QR), and the node does the chain
/// work itself. State lives in `StorageFundingController` so the
/// payment poll survives the hop into the send flow.
@MainActor
struct StorageFundingView: View {
    @Environment(StorageFundingController.self) private var funding
    @Environment(Vault.self) private var vault
    @Environment(\.dismiss) private var dismiss

    /// Start straight in this purchase instead of the plan picker
    /// (extend a running plan).
    var initialPurchase: StorageFundingController.Purchase? = nil
    /// Inside the publish-setup checklist: no navigation chrome, and
    /// the checklist itself moves on once the plan is active.
    var embedded = false

    @State private var selectedPlanID: String = StoragePlan.all[StoragePlan.defaultIndex].id
    @State private var didCopy = false

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                ScrollView {
                    content.padding(20)
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            if let initialPurchase, funding.purchase != initialPurchase || funding.step == .plan {
                await funding.start(initialPurchase)
            } else if funding.step == .plan {
                await funding.loadQuotes()
            }
        }
    }

    private var title: String {
        if case .extend = initialPurchase { return "Extend storage" }
        return "Buy storage"
    }

    @ViewBuilder private var content: some View {
        switch funding.step {
        case .plan:
            if initialPurchase == nil { planPicker } else { startingCard }
        case .payment:
            paymentCard
        case .activating:
            activatingCard
        case .done:
            doneCard
        }
    }

    // MARK: - Plan

    private var planPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a plan").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(StoragePlan.all) { plan in
                    planCard(plan, isSelected: plan.id == selectedPlanID)
                        .onTapGesture { selectedPlanID = plan.id }
                }
            }
            if let quote = funding.quotes[selectedPlanID], quote.includesSettlementDeposit {
                Text("Includes a one-time \(quote.settlementDepositBzz) xBZZ deposit that backs your node's bandwidth payments.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = funding.error {
                VStack(alignment: .leading, spacing: 8) {
                    stampStatusText(error, tint: .red)
                    Button("Try again") { Task { await funding.loadQuotes() } }
                        .font(.callout)
                }
            }
            Button {
                guard let plan = StoragePlan.all.first(where: { $0.id == selectedPlanID }) else { return }
                Task { await funding.start(.buy(plan)) }
            } label: {
                Label("Continue", systemImage: "arrow.right.circle.fill")
            }
            .buttonStyle(PrimaryActionStyle(isEnabled: funding.quotes[selectedPlanID] != nil))
            .disabled(funding.quotes[selectedPlanID] == nil)
        }
    }

    private func planCard(_ plan: StoragePlan, isSelected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.label).font(.callout).fontWeight(.medium)
                Text(plan.description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let quote = funding.quotes[plan.id] {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(quote.totalCostBzz) xBZZ")
                        .font(.callout).monospacedDigit()
                    Text(Self.sendLine(for: quote))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if funding.isLoadingQuotes {
                ProgressView().controlSize(.small)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
            if isSelected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(isSelected ? 0.5 : 0), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    /// What the user actually sends for this plan. The plan's price is
    /// the xBZZ figure; the xDAI differs per node: nothing when the
    /// node is funded, only gas when it already holds the xBZZ, swap
    /// input plus gas otherwise.
    static func sendLine(for quote: StorageQuote) -> String {
        if quote.sufficientFunds { return "node already funded" }
        let xdai = StoragePayment.roundedUpXdai(quote.xdaiToSendDisplay)
        return quote.coveredByNodeBzz ? "send \(xdai) xDAI for fees" : "send \(xdai) xDAI"
    }

    private var startingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = funding.error {
                stampStatusText(error, tint: .red)
                Button("Try again") {
                    if let initialPurchase { Task { await funding.start(initialPurchase) } }
                }
                .font(.callout)
            } else {
                stampStatusText("Pricing…", tint: .secondary)
            }
        }
    }

    // MARK: - Payment

    @ViewBuilder private var paymentCard: some View {
        if let quote = funding.quote {
            let amount = StoragePayment.roundedUpXdai(quote.xdaiToSendDisplay)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(purchaseTitle).font(.headline)
                    Text("Send \(amount) xDAI on Gnosis Chain to your node. It buys the plan on its own once the transfer lands.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Self.coverageLine(for: quote))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let nodeAddress {
                    qrCard(uri: StoragePayment.paymentURI(nodeAddress: nodeAddress, xdai: amount))
                    nodeAddressRow(nodeAddress)
                    NavigationLink {
                        SendFlowView(chain: .gnosis, recipient: nodeAddress, amount: amount)
                    } label: {
                        Label("Pay from Freedom wallet", systemImage: "arrow.up.right.circle.fill")
                    }
                    .buttonStyle(PrimaryActionStyle())
                } else {
                    stampStatusText("Unlock the wallet to see your node's address.", tint: .secondary)
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for payment · node holds \(quote.accountXdaiDisplay) xDAI")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await funding.refreshQuote() }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Check again")
                }
                if let error = funding.error {
                    VStack(alignment: .leading, spacing: 8) {
                        stampStatusText(error, tint: .red)
                        if quote.sufficientFunds {
                            Button("Activate again") { Task { await funding.activate() } }
                                .font(.callout)
                        }
                    }
                }
                if !embedded, initialPurchase == nil {
                    Button("Choose another plan") { funding.back() }
                        .font(.callout)
                }
            }
        }
    }

    /// What the xDAI pays for: the plan costs `totalCostBzz` xBZZ either
    /// way; the node swaps for what it lacks and keeps a small reserve
    /// for its own transactions.
    static func coverageLine(for quote: StorageQuote) -> String {
        var parts: [String] = []
        if quote.coveredByNodeBzz {
            parts.append("Your node already holds the \(quote.totalCostBzz) xBZZ this plan costs, so the xDAI only covers its transaction fees.")
        } else {
            parts.append("Covers the \(quote.totalCostBzz) xBZZ this plan costs (your node swaps for it) plus a small reserve for its transaction fees.")
        }
        if quote.includesSettlementDeposit {
            parts.append("Includes a one-time \(quote.settlementDepositBzz) xBZZ deposit that backs your node's bandwidth payments.")
        }
        return parts.joined(separator: " ")
    }

    private var purchaseTitle: String {
        switch funding.purchase {
        case .buy(let plan): "\(plan.label) · \(plan.description)"
        case .extend(let days): "Extend by \(days) days"
        case nil: ""
        }
    }

    private var nodeAddress: String? {
        try? vault.signingKey(at: .beeWallet).ethereumAddress
    }

    private func qrCard(uri: String) -> some View {
        Group {
            if let image = Self.generateQR(content: uri) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                    .padding(12)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Payment request QR code")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func nodeAddressRow(_ address: String) -> some View {
        Button {
            UIPasteboard.general.string = address
            withAnimation { didCopy = true }
            Task {
                try? await Task.sleep(for: .milliseconds(1500))
                withAnimation { didCopy = false }
            }
        } label: {
            HStack(spacing: 8) {
                Text(address)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.footnote)
                    .foregroundStyle(didCopy ? Color.green : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy node address")
    }

    // MARK: - Activating / done

    private var activatingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView()
                Text(activatingLabel).font(.callout)
            }
            Text(activatingDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var activatingLabel: String {
        if case .extend = funding.purchase { return "Extending your plan…" }
        return "Activating your plan…"
    }

    private var activatingDetail: String {
        let covered = funding.quote?.coveredByNodeBzz ?? false
        let how = covered
            ? "Your node pays with the xBZZ it already holds and submits the transactions."
            : "Your node swaps xDAI for xBZZ and submits the transactions."
        return how + " Usually one to two minutes on Gnosis — keep the app open."
    }

    private var doneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            stampStatusText(doneLabel, tint: .green)
            if !embedded {
                Button("Done") {
                    funding.reset()
                    dismiss()
                }
                .buttonStyle(PrimaryActionStyle())
            }
        }
    }

    private var doneLabel: String {
        if case .extend = funding.purchase { return "Plan extended." }
        return "Plan active. It becomes usable in about a minute."
    }

    private static func generateQR(content: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
