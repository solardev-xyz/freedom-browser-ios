import BigInt
import SwiftUI
import web3

@MainActor
struct SendFlowView: View {
    @Environment(Vault.self) private var vault
    @Environment(ChainRegistry.self) private var chains
    @Environment(TransactionService.self) private var txService
    @Environment(ENSResolver.self) private var ensResolver

    @AppStorage(WalletDefaults.activeChainID) private var activeChainID: Int = Chain.defaultChain.id

    @State private var recipientInput = ""
    @State private var amountInput = ""
    @State private var recipientState: RecipientState = .idle
    @State private var recipientTask: Task<Void, Never>?
    @State private var quoteState: QuoteState = .idle
    @State private var quoteTask: Task<Void, Never>?

    /// Recipient input → resolved address state machine. Hex addresses
    /// resolve synchronously; ENS names go through the consensus pipeline,
    /// which is the slow path we surface explicitly so the user knows
    /// what's happening. `reverseInFlight` is the analogous flag for the
    /// reverse-lookup latency so users typing hex see the same "looking
    /// up" affordance as users typing names.
    private enum RecipientState: Equatable {
        case idle
        case invalid(message: String)
        case resolving(name: String)
        case resolved(EthereumAddress, ensName: String?, reverseInFlight: Bool)
        case resolveFailed(message: String)
    }

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

    private var validatedAmount: BigUInt? {
        guard let parsed = BalanceFormatter.parseAmount(amountInput), parsed > 0 else { return nil }
        return parsed
    }

    private var resolvedRecipient: EthereumAddress? {
        if case .resolved(let address, _, _) = recipientState { return address }
        return nil
    }

    private var resolvedENSName: String? {
        if case .resolved(_, let name, _) = recipientState { return name }
        return nil
    }

    private struct ReviewInputs {
        let recipient: EthereumAddress
        let recipientName: String?
        let amount: BigUInt
        let quote: TransactionService.Quote
    }

    private var reviewInputs: ReviewInputs? {
        guard let recipient = resolvedRecipient,
              let amount = validatedAmount,
              case .ready(let quote) = quoteState else { return nil }
        return ReviewInputs(
            recipient: recipient, recipientName: resolvedENSName,
            amount: amount, quote: quote
        )
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
        .onChange(of: recipientInput) { _, _ in scheduleResolution() }
        .onChange(of: amountInput) { _, _ in scheduleQuote() }
        .onDisappear {
            recipientTask?.cancel()
            quoteTask?.cancel()
        }
    }

    private var recipientSection: some View {
        Section {
            TextField("0x… or vitalik.eth", text: $recipientInput)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            recipientFooter
        } header: {
            Text("Recipient")
        }
    }

    @ViewBuilder private var recipientFooter: some View {
        switch recipientState {
        case .idle:
            EmptyView()
        case .invalid(let message), .resolveFailed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        case .resolving(let name):
            HStack {
                ProgressView().controlSize(.small)
                Text("Resolving \(name)…").font(.caption).foregroundStyle(.secondary)
            }
        case .resolved(let address, let ensName, let reverseInFlight):
            // User typed a name → show resolved hex underneath.
            // User typed hex → spinner during reverse, then name on hit
            // (silent if no primary name set — most random addresses).
            let inputIsHex = Hex.isAddressShape(recipientInput.trimmingCharacters(in: .whitespaces))
            if inputIsHex {
                if reverseInFlight {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Looking up name…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let ensName {
                    Text(ensName).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            } else if ensName != nil {
                Text("→ \(address.toChecksumAddress())")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
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
                        recipientName: inputs.recipientName,
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

    // MARK: - Resolution + quoting

    private func scheduleResolution() {
        recipientTask?.cancel()
        let trimmed = recipientInput.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            recipientState = .idle
            scheduleQuote()
            return
        }
        if Hex.isAddressShape(trimmed) {
            let address = EthereumAddress(trimmed)
            recipientState = .resolved(address, ensName: nil, reverseInFlight: true)
            scheduleQuote()
            // Best-effort reverse lookup for the recipient subtitle —
            // silent on failure, hex stays the canonical recipient.
            recipientTask = Task { await reverseLookupRecipient(address: address, hexInput: trimmed) }
            return
        }
        if isENSShape(trimmed) {
            recipientState = .resolving(name: trimmed)
            scheduleQuote()  // clears any prior fee
            recipientTask = Task { await resolveENS(name: trimmed) }
            return
        }
        recipientState = .invalid(message: "Enter 0x… or an ENS name ending in .eth or .box.")
        scheduleQuote()
    }

    private func reverseLookupRecipient(address: EthereumAddress, hexInput: String) async {
        let name = try? await ensResolver.reverseResolve(address: address)
        if Task.isCancelled { return }
        // Guard against the user having moved on to a different recipient
        // before the lookup returned.
        guard recipientInput.trimmingCharacters(in: .whitespaces) == hexInput else { return }
        if case .resolved = recipientState {
            recipientState = .resolved(address, ensName: name ?? nil, reverseInFlight: false)
        }
    }

    private func resolveENS(name: String) async {
        // Same 400ms debounce as the quote path — ENS consensus costs 1-2s
        // RPC time so we shouldn't fire it on every keystroke.
        try? await Task.sleep(for: .milliseconds(400))
        if Task.isCancelled { return }
        do {
            let address = try await ensResolver.resolveAddress(name)
            if Task.isCancelled { return }
            recipientState = .resolved(address, ensName: name, reverseInFlight: false)
            // The user's intent is already settled by the time we get here
            // (consensus + cache hit took 0–2s); skip the quote debounce
            // that would otherwise stack another 400ms on top.
            await refreshQuoteIfReady()
        } catch {
            if Task.isCancelled { return }
            recipientState = .resolveFailed(message: ENSErrorFormatting.describe(error))
        }
    }

    private func refreshQuoteIfReady() async {
        quoteTask?.cancel()
        guard let recipient = resolvedRecipient, let amount = validatedAmount else {
            quoteState = .idle
            return
        }
        quoteState = .loading
        await refreshQuote(recipient: recipient, amount: amount)
    }

    private func isENSShape(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.hasSuffix(".eth") || lower.hasSuffix(".box")
    }

    private func scheduleQuote() {
        quoteTask?.cancel()
        guard let recipient = resolvedRecipient, let amount = validatedAmount else {
            quoteState = .idle
            return
        }
        quoteState = .loading
        quoteTask = Task {
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
