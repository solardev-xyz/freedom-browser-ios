import BigInt
import SwiftUI
import web3

@MainActor
struct SendFlowView: View {
    @Environment(Vault.self) private var vault
    @Environment(ChainRegistry.self) private var chains
    @Environment(TransactionService.self) private var txService
    @Environment(ENSResolver.self) private var ensResolver

    /// Chain + asset are local @State, defaulted from the caller. Switching
    /// either via the picker doesn't write back to `WalletDefaults.activeChainID`
    /// — the user can be browsing on Gnosis but send ETH without losing
    /// their home view state.
    @State private var chain: Chain
    @State private var asset: Token

    @State private var recipientInput = ""
    @State private var amountInput = ""
    @State private var recipientState: RecipientState = .idle
    @State private var recipientTask: Task<Void, Never>?
    @State private var quoteState: QuoteState = .idle
    @State private var quoteTask: Task<Void, Never>?
    @State private var balance: BigUInt?

    init(chain: Chain, asset: Token? = nil) {
        self._chain = State(initialValue: chain)
        self._asset = State(initialValue: asset ?? TokenRegistry.native(for: chain))
    }

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
            case (.ready, .ready): return true
            default: return false
            }
        }
    }

    private var validatedAmount: BigUInt? {
        guard let parsed = BalanceFormatter.parseAmount(amountInput, decimals: asset.decimals),
              parsed > 0 else { return nil }
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
            fromSection
            recipientSection
            amountSection
            feeSection
            reviewSection
        }
        .navigationTitle("Send")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: recipientInput) { _, _ in scheduleResolution() }
        .onChange(of: amountInput) { _, _ in scheduleQuote() }
        .onChange(of: asset) { _, _ in onAssetChanged() }
        .task(id: asset) { await refreshBalance() }
        .onDisappear {
            recipientTask?.cancel()
            quoteTask?.cancel()
        }
    }

    // MARK: - From row

    private var fromSection: some View {
        Section {
            NavigationLink {
                AssetPickerView(selectedChain: $chain, selectedAsset: $asset)
            } label: {
                HStack(spacing: 12) {
                    TokenLogo(token: asset)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(asset.symbol)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(chain.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let balance {
                        Text(BalanceFormatter.formatAmount(wei: balance, decimals: asset.decimals))
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("From")
        }
    }

    // MARK: - Recipient

    private var recipientSection: some View {
        Section {
            TextField("0x… or vitalik.eth", text: $recipientInput)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            recipientFooter
        } header: {
            Text("To")
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

    // MARK: - Amount

    private var amountSection: some View {
        Section {
            HStack {
                TextField("0.0", text: $amountInput)
                    .keyboardType(.decimalPad)
                Spacer()
                Button("Max") { fillMax() }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                    .disabled(balance == nil || balance == 0)
            }
            if !amountInput.trimmingCharacters(in: .whitespaces).isEmpty,
               validatedAmount == nil {
                Text("Enter a positive amount with up to \(asset.decimals) decimal places.")
                    .font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Amount")
        }
    }

    /// For native: leave room for the gas fee (estimate not always
    /// available, so fall back to balance and let prepare/insufficient-
    /// funds catch it). For ERC-20: gas is paid in native, so the full
    /// token balance is sendable.
    private func fillMax() {
        guard let balance else { return }
        let maxValue: BigUInt
        if asset.isNative, case .ready(let quote) = quoteState {
            maxValue = balance > quote.maxFeeWei ? balance - quote.maxFeeWei : 0
        } else {
            maxValue = balance
        }
        amountInput = BalanceFormatter.formatAmount(wei: maxValue, decimals: asset.decimals, maxFractionDigits: asset.decimals)
    }

    // MARK: - Fee

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
                Text(BalanceFormatter.format(wei: quote.maxFeeWei, symbol: chain.nativeSymbol))
                    .font(.system(.body, design: .monospaced))
            }
        case .failed(let message):
            Section("Estimated fee") {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Review

    @ViewBuilder private var reviewSection: some View {
        Section {
            if let inputs = reviewInputs {
                NavigationLink("Review") {
                    SendReviewView(
                        recipient: inputs.recipient,
                        recipientName: inputs.recipientName,
                        amount: inputs.amount,
                        quote: inputs.quote,
                        chain: chain,
                        token: asset
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
            recipientTask = Task { await reverseLookupRecipient(address: address, hexInput: trimmed) }
            return
        }
        if isENSShape(trimmed) {
            recipientState = .resolving(name: trimmed)
            scheduleQuote()
            recipientTask = Task { await resolveENS(name: trimmed) }
            return
        }
        recipientState = .invalid(message: "Enter 0x… or an ENS name ending in .eth or .box.")
        scheduleQuote()
    }

    private func reverseLookupRecipient(address: EthereumAddress, hexInput: String) async {
        let name = try? await ensResolver.reverseResolve(address: address)
        if Task.isCancelled { return }
        guard recipientInput.trimmingCharacters(in: .whitespaces) == hexInput else { return }
        if case .resolved = recipientState {
            recipientState = .resolved(address, ensName: name ?? nil, reverseInFlight: false)
        }
    }

    private func resolveENS(name: String) async {
        try? await Task.sleep(for: .milliseconds(400))
        if Task.isCancelled { return }
        do {
            let address = try await ensResolver.resolveAddress(name)
            if Task.isCancelled { return }
            recipientState = .resolved(address, ensName: name, reverseInFlight: false)
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
        let txParams: (to: EthereumAddress, value: BigUInt, data: Data)
        do {
            txParams = try TransactionService.buildSend(token: asset, recipient: recipient, amount: amount)
        } catch {
            quoteState = .failed("Couldn't encode token transfer.")
            return
        }
        do {
            let newQuote = try await txService.prepare(
                from: EthereumAddress(fromHex),
                to: txParams.to,
                valueWei: txParams.value,
                data: txParams.data,
                on: chain
            )
            if Task.isCancelled { return }
            quoteState = .ready(newQuote)
        } catch TransactionService.Error.insufficientBalance {
            if Task.isCancelled { return }
            quoteState = .failed("Not enough \(chain.nativeSymbol) to cover the amount plus the network fee.")
        } catch {
            if Task.isCancelled { return }
            quoteState = .failed("Couldn't estimate fee. Check connection.")
        }
    }

    /// Decimals may differ between the old and new asset, so a "10.5"
    /// string typed against USDC (6 decimals) would be invalid against
    /// an 18-decimal asset. Clear and let the user re-type. The picker
    /// is the only `chain`/`asset` mutator and always writes both
    /// atomically, so a separate chain handler isn't needed.
    private func onAssetChanged() {
        amountInput = ""
        quoteState = .idle
    }

    // MARK: - Balance fetch (for Max button + From row)

    private func refreshBalance() async {
        guard let derived = try? vault.signingKey(at: .mainUser).ethereumAddress else {
            balance = nil
            return
        }
        let fetcher = TokenBalanceFetcher(walletRPC: chains.walletRPC)
        let result = await fetcher.fetch(
            holder: EthereumAddress(derived), chain: chain, tokens: [asset]
        )
        balance = result[asset]
    }
}
