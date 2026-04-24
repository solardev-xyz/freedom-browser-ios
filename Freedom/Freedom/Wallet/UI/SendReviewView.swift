import BigInt
import SwiftUI
import web3

@MainActor
struct SendReviewView: View {
    let recipient: EthereumAddress
    let amount: BigUInt
    let quote: TransactionService.Quote
    let chain: Chain

    @Environment(TransactionService.self) private var txService
    @Environment(\.closeWalletSheet) private var closeWalletSheet

    @State private var stage: Stage = .form(isBroadcasting: false)
    @State private var confirmationTask: Task<Void, Never>?

    private enum Stage {
        case form(isBroadcasting: Bool)
        case inFlight(hash: String, outcome: Outcome)
        case failed(message: String)

        enum Outcome {
            case pending
            case confirmed(block: Int)
            case timedOut
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch stage {
                case .form(let isBroadcasting):
                    details
                    PrimaryActionButton(
                        title: "Confirm send",
                        busyTitle: "Broadcasting…",
                        isWorking: isBroadcasting,
                        action: { Task { await broadcast() } }
                    )
                case .inFlight(let hash, let outcome):
                    statusBanner(outcome: outcome)
                    hashCard(hash)
                    explorerLink(hash)
                    if case .pending = outcome { EmptyView() } else { doneButton }
                case .failed(let message):
                    VaultFailureView(
                        title: "Send failed",
                        message: message,
                        onRetry: { stage = .form(isBroadcasting: false) }
                    )
                }
            }
            .padding(20)
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { confirmationTask?.cancel() }
    }

    private var navigationTitle: String {
        switch stage {
        case .form: return "Review"
        case .inFlight: return "Transaction"
        case .failed: return "Send failed"
        }
    }

    // MARK: - Review pane

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Network", chain.displayName)
            divider
            row("To", recipient.asString())
            divider
            row("Amount", BalanceFormatter.format(wei: amount, symbol: chain.nativeSymbol))
            divider
            row("Network fee (max)", BalanceFormatter.format(wei: quote.maxFeeWei, symbol: chain.nativeSymbol))
            divider
            row("Total (max)", BalanceFormatter.format(wei: amount + quote.maxFeeWei, symbol: chain.nativeSymbol))
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 8)
    }

    private var divider: some View {
        Divider().opacity(0.3)
    }

    // MARK: - In-flight pane

    private func statusBanner(outcome: Stage.Outcome) -> some View {
        HStack(spacing: 12) {
            switch outcome {
            case .pending:
                ProgressView().controlSize(.large)
                Text("Pending").font(.title2.weight(.semibold))
            case .confirmed(let block):
                Image(systemName: "checkmark.seal.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Confirmed").font(.title2.weight(.semibold))
                    Text("At block \(block)").font(.caption).foregroundStyle(.secondary)
                }
            case .timedOut:
                Image(systemName: "clock.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Still pending").font(.title2.weight(.semibold))
                    Text("Check the explorer for status.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func hashCard(_ hash: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Transaction hash").font(.caption).foregroundStyle(.secondary)
            AddressPill(address: hash)
        }
    }

    private func explorerLink(_ hash: String) -> some View {
        Link(destination: chain.explorerURL(forTx: hash)) {
            Label("View on \(chain.displayName) explorer", systemImage: "arrow.up.forward.app")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var doneButton: some View {
        Button("Done") { closeWalletSheet() }
            .buttonStyle(PrimaryActionStyle())
    }

    // MARK: - Actions

    private func broadcast() async {
        stage = .form(isBroadcasting: true)
        do {
            let hash = try await txService.send(
                to: recipient,
                valueWei: amount,
                quote: quote,
                on: chain
            )
            stage = .inFlight(hash: hash, outcome: .pending)
            confirmationTask = Task { await awaitConfirmation(hash: hash) }
        } catch {
            stage = .failed(message: error.localizedDescription)
        }
    }

    private func awaitConfirmation(hash: String) async {
        do {
            let block = try await txService.awaitConfirmation(hash: hash, on: chain)
            if Task.isCancelled { return }
            stage = .inFlight(hash: hash, outcome: .confirmed(block: block))
        } catch {
            if Task.isCancelled { return }
            stage = .inFlight(hash: hash, outcome: .timedOut)
        }
    }
}
