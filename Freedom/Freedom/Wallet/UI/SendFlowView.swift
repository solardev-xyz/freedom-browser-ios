import BigInt
import SwiftUI
import web3

@MainActor
struct SendFlowView: View {
    @Environment(Vault.self) private var vault
    @Environment(ChainRegistry.self) private var chains
    @Environment(TransactionService.self) private var txService

    @AppStorage(WalletDefaults.activeChainID) private var activeChainID: Int = Chain.defaultChain.id

    @State private var recipientInput = ""
    @State private var amountInput = ""
    @State private var quoteState: QuoteState = .idle
    @State private var quoteTask: Task<Void, Never>?

    private enum QuoteState: Equatable {
        case idle
        case loading
        case ready(TransactionService.Quote)
        case failed(String)

        static func == (lhs: QuoteState, rhs: QuoteState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading): return true
            case (.failed(let a), .failed(let b)): return a == b
            case (.ready, .ready): return true  // Quote isn't Equatable; identity is enough for view diffing
            default: return false
            }
        }
    }

    private var activeChain: Chain {
        Chain.find(id: activeChainID) ?? .defaultChain
    }

    /// `EthereumAddress.init(_:)` is non-throwing and accepts any string;
    /// we validate shape ourselves so bad input surfaces as a visible
    /// error instead of silently producing a zero address.
    private var validatedRecipient: EthereumAddress? {
        let trimmed = recipientInput.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("0x"), trimmed.count == 42,
              trimmed.dropFirst(2).allSatisfy({ $0.isHexDigit }) else { return nil }
        return EthereumAddress(trimmed)
    }

    private var validatedAmount: BigUInt? {
        guard let parsed = BalanceFormatter.parseAmount(amountInput), parsed > 0 else { return nil }
        return parsed
    }

    private struct ReviewInputs {
        let recipient: EthereumAddress
        let amount: BigUInt
        let quote: TransactionService.Quote
    }

    private var reviewInputs: ReviewInputs? {
        guard let recipient = validatedRecipient,
              let amount = validatedAmount,
              case .ready(let quote) = quoteState else { return nil }
        return ReviewInputs(recipient: recipient, amount: amount, quote: quote)
    }

    var body: some View {
        Form {
            recipientSection
            amountSection
            feeSection
            reviewSection
        }
        .navigationTitle("Send \(activeChain.nativeSymbol)")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: recipientInput) { _, _ in scheduleQuote() }
        .onChange(of: amountInput) { _, _ in scheduleQuote() }
        .onDisappear { quoteTask?.cancel() }
    }

    private var recipientSection: some View {
        Section {
            TextField("0x…", text: $recipientInput)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !recipientInput.trimmingCharacters(in: .whitespaces).isEmpty,
               validatedRecipient == nil {
                Text("Must be a 0x-prefixed Ethereum address (42 characters).")
                    .font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Recipient")
        } footer: {
            Text("ENS name support lands in a future update — paste a hex address for now.")
                .font(.caption2)
        }
    }

    private var amountSection: some View {
        Section("Amount") {
            HStack {
                TextField("0.0", text: $amountInput)
                    .keyboardType(.decimalPad)
                Text(activeChain.nativeSymbol)
                    .foregroundStyle(.secondary)
            }
            if !amountInput.trimmingCharacters(in: .whitespaces).isEmpty,
               validatedAmount == nil {
                Text("Enter a positive amount with up to 18 decimal places.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var feeSection: some View {
        switch quoteState {
        case .idle:
            EmptyView()
        case .loading:
            Section("Estimated fee") {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Estimating…").foregroundStyle(.secondary)
                }
            }
        case .ready(let quote):
            Section("Estimated fee") {
                Text(BalanceFormatter.format(wei: quote.maxFeeWei, symbol: activeChain.nativeSymbol))
                    .font(.system(.body, design: .monospaced))
            }
        case .failed(let message):
            Section("Estimated fee") {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var reviewSection: some View {
        Section {
            if let inputs = reviewInputs {
                NavigationLink("Review") {
                    SendReviewView(
                        recipient: inputs.recipient,
                        amount: inputs.amount,
                        quote: inputs.quote,
                        chain: activeChain
                    )
                }
            } else {
                Text("Review")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func scheduleQuote() {
        quoteTask?.cancel()
        guard let recipient = validatedRecipient, let amount = validatedAmount else {
            quoteState = .idle
            return
        }
        quoteState = .loading
        quoteTask = Task {
            // 400ms debounce swallows typing bursts and gives a user who's
            // finished a near-instant fee estimate when they look up.
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            await refreshQuote(recipient: recipient, amount: amount)
        }
    }

    private func refreshQuote(recipient: EthereumAddress, amount: BigUInt) async {
        guard let fromHex = try? vault.signingKey(at: .mainUser).ethereumAddress else {
            quoteState = .failed("Wallet locked — reopen to retry.")
            return
        }
        do {
            let newQuote = try await txService.prepare(
                from: EthereumAddress(fromHex),
                to: recipient,
                valueWei: amount,
                data: Data(),
                on: activeChain
            )
            if Task.isCancelled { return }
            quoteState = .ready(newQuote)
        } catch {
            if Task.isCancelled { return }
            quoteState = .failed("Couldn't estimate fee. Check connection.")
        }
    }
}
