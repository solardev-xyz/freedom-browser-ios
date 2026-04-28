import BigInt
import SwarmKit
import SwiftUI
import web3

/// Four-step checklist that takes a user from ultralight to a fully-synced
/// light node with a usable stamp. Step 1 is the one-tx funder
/// (`SwarmNodeFunder.fundNodeAndBuyStamp`). Step 2 is passive watching of
/// the live `/chainstate` percent during the bundled-snapshot ingest.
/// Step 3 is the post-sync chequebook confirmation — bee's chequebook
/// subsystem only comes online once the node is `.ready`, so this is the
/// first moment we can verify the on-chain deploy from step 1 succeeded.
/// Step 4 is the stamp purchase, which pushes `StampPurchaseView` and
/// auto-completes when `StampService.hasUsableStamps` flips true (also
/// covers returning users with stamps from a prior session).
@MainActor
struct PublishSetupView: View {
    @Environment(SwarmNode.self) private var swarm
    @Environment(SettingsStore.self) private var settings
    @Environment(BeeIdentityCoordinator.self) private var beeIdentity
    @Environment(BeeReadiness.self) private var beeReadiness
    @Environment(StampService.self) private var stampService
    @Environment(Vault.self) private var vault
    @Environment(TransactionService.self) private var txService
    @Environment(ChainRegistry.self) private var chains

    /// Three quick-fill amounts in xDAI (swap portion only — the 0.05
    /// xDAI for chequebook gas is added on top by the contract math).
    private static let presets: [(label: String, swapXdai: Double)] = [
        ("Try out", 1.0),
        ("Recommended", 5.0),
        ("Generous", 10.0),
    ]

    @State private var swapInput: String = "1.00"
    @State private var spotXdaiPerBzz: Double?
    @State private var mainWalletXdai: BigUInt?
    @State private var isSending: Bool = false
    @State private var sendError: String?
    @State private var showQuoteDetails: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                step1
                step2
                step3
                step4
            }
            .padding(20)
        }
        .navigationTitle("Setup publishing")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshAll() }
        .alert(
            "Funding failed",
            isPresented: Binding(
                get: { sendError != nil },
                set: { if !$0 { sendError = nil } }
            ),
            presenting: sendError
        ) { _ in
            Button("OK") { sendError = nil }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Steps

    private var step1: some View {
        PublishStepRow(
            number: 1,
            title: "Fund and upgrade",
            summary: step1Copy,
            status: step1Status
        ) {
            step1ActiveBody  // PublishStepRow only renders when status == .active
        }
    }

    private var step2: some View {
        PublishStepRow(
            number: 2,
            title: "Syncing light node",
            summary: step2Copy,
            status: step2Status
        ) {
            Group {
                if case .syncingPostage(let percent, _, _) = beeReadiness.state {
                    ProgressView(value: Double(percent), total: 100)
                        .progressViewStyle(.linear)
                }
            }
        }
    }

    private var step3: some View {
        PublishStepRow(
            number: 3,
            title: "Chequebook deployed",
            summary: step3Copy,
            status: step3Status
        ) { EmptyView() }
    }

    private var step4: some View {
        PublishStepRow(
            number: 4,
            title: "Buy your first stamp",
            summary: step4Copy,
            status: step4Status
        ) {
            // Active body shows up only once bee is ready (step3 done) —
            // before that the button can't do anything useful.
            Group {
                if step4Status == .active {
                    NavigationLink {
                        StampPurchaseView()
                    } label: {
                        Label("Buy your first stamp", systemImage: "cart.fill")
                    }
                    .buttonStyle(PrimaryActionStyle())
                }
            }
        }
    }

    // MARK: - Step copy + status

    private var step1Copy: String {
        if step1Status == .completed {
            return "Done. Your Bee node is funded and running in light mode."
        }
        return "One transaction from your main wallet swaps xDAI for xBZZ and forwards a small amount of xDAI to your Bee node for chequebook deploy gas."
    }

    private var step2Copy: String {
        if case .syncingPostage(let percent, let lastSynced, let head) = beeReadiness.state {
            if head > 0 {
                return "\(percent)% · block \(lastSynced.formatted()) of \(head.formatted())"
            }
            return "Block \(lastSynced.formatted())"
        }
        if case .startingUp = beeReadiness.state {
            return "Connecting to Gnosis…"
        }
        return "Bee catches up to the chain. Takes a few minutes — please keep the app open."
    }

    private var step3Copy: String {
        if let addr = beeReadiness.chequebookAddress {
            return "Chequebook \(addr.shortenedHex())"
        }
        // Reached `.ready` but the one-shot address fetch failed —
        // chequebook is deployed (bee wouldn't be ready otherwise),
        // we just couldn't display it. Don't show the pending copy.
        if step3Status == .completed { return "Chequebook deployed." }
        return "Confirms once your light node has finished syncing."
    }

    private var step4Copy: String {
        if step4Status == .completed {
            return "Done. Your node has a usable postage stamp."
        }
        return "Postage stamps pre-pay the network for storing your data."
    }

    /// Where the user currently is in the funnel. Step 3 (chequebook
    /// confirmed) auto-completes the moment we hit `.stamp`, so it
    /// doesn't get its own phase ordinal.
    private enum Phase: Int, Comparable {
        case fund        // step 1 active
        case sync        // step 2 active (passive watching, % from /chainstate)
        case stamp       // step 4 active — also flips step 3 to .completed

        static func < (lhs: Phase, rhs: Phase) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private var phase: Phase {
        if settings.beeNodeMode == .ultraLight { return .fund }
        switch beeReadiness.state {
        case .browsingOnly, .initializing, .startingUp, .syncingPostage: return .sync
        case .ready: return .stamp
        }
    }

    private func status(at step: Phase, waitingWhenActive: Bool = true) -> PublishStepStatus {
        if phase > step { return .completed }
        if phase < step { return .pending }
        return waitingWhenActive ? .waiting : .active
    }

    private var step1Status: PublishStepStatus { status(at: .fund, waitingWhenActive: false) }
    private var step2Status: PublishStepStatus { status(at: .sync) }
    private var step3Status: PublishStepStatus {
        // Auto-completes on .ready (`/chequebook/address` is the first
        // post-sync verifiable signal that step 1's tx succeeded).
        phase >= .stamp ? .completed : .pending
    }
    private var step4Status: PublishStepStatus {
        // Pending until bee is ready, then `.active` (button visible) or
        // `.completed` (user already has a usable stamp). Source of
        // truth lives in `StampService` — it polls `/stamps` and is
        // updated immediately after a successful purchase.
        if phase < .stamp { return .pending }
        if stampService.hasUsableStamps { return .completed }
        return .active
    }

    // MARK: - Step 1 body (active state)

    @ViewBuilder private var step1ActiveBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            amountInput
            presetChips
            quoteDisclosure
            // Same button shape for both branches — only label + action
            // differ. Insufficient balance shows the receive flow; sufficient
            // balance shows the fund-and-upgrade tx.
            Group {
                if !hasSufficientBalance {
                    insufficientBalanceCTA
                } else {
                    fundButton
                }
            }
        }
    }

    private var amountInput: some View {
        HStack {
            Text("Swap").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            TextField("amount", text: $swapInput)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
            Text("xDAI").font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var presetChips: some View {
        HStack(spacing: 8) {
            ForEach(Array(Self.presets.enumerated()), id: \.offset) { _, preset in
                Button {
                    swapInput = String(format: "%.2f", preset.swapXdai)
                } label: {
                    let active = isPresetActive(preset.swapXdai)
                    VStack(spacing: 1) {
                        Text(preset.label).font(.caption).fontWeight(.medium)
                        Text("\(Int(preset.swapXdai)) xDAI")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(active ? Color.accentColor.opacity(0.15) : Color(.tertiarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor.opacity(active ? 0.5 : 0), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// True when the typed amount equals the preset (within float noise).
    /// Drives the subtle highlight on whichever chip the user just picked.
    private func isPresetActive(_ swapXdai: Double) -> Bool {
        guard let amount = swapAmountWei else { return false }
        let target = BigUInt(swapXdai * 1e18)
        return amount == target
    }

    /// Tucked behind a disclosure so a novice user isn't confronted with
    /// swap math, gas reservations, and slippage on first open. Power
    /// users tap "Show details" to expand.
    @ViewBuilder private var quoteDisclosure: some View {
        if let swap = swapAmountWei {
            DisclosureGroup(
                isExpanded: $showQuoteDetails,
                content: {
                    VStack(alignment: .leading, spacing: 4) {
                        quoteRow(
                            label: "Swap",
                            value: "\(formatXdai(swap)) → \(formattedExpectedBzz)"
                        )
                        quoteRow(
                            label: "Network",
                            value: "\(formatXdai(SwarmFunderConstants.xdaiForBeeWei)) for chequebook gas"
                        )
                        Divider().opacity(0.3)
                        quoteRow(
                            label: "Total",
                            value: "\(formatXdai(swap + SwarmFunderConstants.xdaiForBeeWei)) + tx gas",
                            valueWeight: .semibold
                        )
                    }
                    .padding(.top, 6)
                },
                label: {
                    Text("Show details")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            )
        }
    }

    private var fundButton: some View {
        Button {
            Task { await fundAndUpgrade() }
        } label: {
            Label(
                isSending ? "Sending…" : "Fund and upgrade",
                systemImage: isSending ? "hourglass" : "arrow.up.circle.fill"
            )
        }
        .buttonStyle(PrimaryActionStyle(isEnabled: canFund))
        .disabled(!canFund)
    }

    /// CTA shown when the main wallet hasn't got enough xDAI for the
    /// selected amount. Pushes `ReceiveView` onto the same NavigationStack
    /// (NodeSheet's) so the QR + copy flow lands the user back here when
    /// they pop. Polling auto-detects the new balance and flips this back
    /// to the regular fund button.
    @ViewBuilder private var insufficientBalanceCTA: some View {
        if mainWalletXdai != nil {
            Text("Top up your wallet with xDAI to continue.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            NavigationLink {
                ReceiveView()
            } label: {
                Label("Top up wallet", systemImage: "arrow.down.left.circle.fill")
            }
            .buttonStyle(PrimaryActionStyle())
        } else {
            // Balance not yet read — soft skeleton avoids flashing the
            // CTA on the first frame before the fetch returns.
            Text("Checking balance…")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func quoteRow(
        label: String,
        value: String,
        valueWeight: Font.Weight = .regular
    ) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout).fontWeight(valueWeight)
        }
    }

    // MARK: - Derived state

    private var swapAmountWei: BigUInt? {
        BalanceFormatter.parseAmount(swapInput)
    }

    private var totalXdaiNeeded: BigUInt? {
        swapAmountWei.map { $0 + SwarmFunderConstants.xdaiForBeeWei }
    }

    private var hasSufficientBalance: Bool {
        guard let need = totalXdaiNeeded, let have = mainWalletXdai else { return true }
        return have >= need
    }

    private var canFund: Bool {
        guard !isSending,
              let amount = swapAmountWei,
              amount > 0,
              hasSufficientBalance,
              vault.state == .unlocked else { return false }
        return true
    }

    private var formattedExpectedBzz: String {
        guard let amount = swapAmountWei, let spot = spotXdaiPerBzz, spot > 0 else {
            return "—"
        }
        let result = SwarmFunderQuote.quote(
            xdaiForSwapWei: amount,
            spotXdaiPerBzz: spot
        )
        let formatted = BalanceFormatter.formatAmount(
            wei: result.expectedBzzPlur,
            decimals: SwarmFunderConstants.bzzDecimals,
            maxFractionDigits: 4
        )
        return "~\(formatted) xBZZ"
    }

    private var mainAddress: String? {
        try? vault.signingKey(at: .mainUser).ethereumAddress
    }

    private func formatXdai(_ wei: BigUInt) -> String {
        BalanceFormatter.format(
            wei: wei,
            decimals: 18,
            symbol: "xDAI",
            maxFractionDigits: 4
        )
    }

    // MARK: - Side-effect tasks

    private func refreshAll() async {
        await refreshSpotPrice()
        await refreshBalance()
    }

    private func refreshSpotPrice() async {
        let pool = SwarmFunderPool(walletRPC: chains.walletRPC)
        if let spot = try? await pool.fetchSpotXdaiPerBzz() {
            spotXdaiPerBzz = spot
        }
    }

    private func refreshBalance() async {
        guard let address = mainAddress else { return }
        let fetcher = TokenBalanceFetcher(walletRPC: chains.walletRPC)
        let xdai = TokenRegistry.native(for: .gnosis)
        let result = await fetcher.fetch(
            holder: EthereumAddress(address),
            chain: .gnosis,
            tokens: [xdai]
        )
        if let balance = result[xdai] {
            mainWalletXdai = balance
        }
    }

    private func fundAndUpgrade() async {
        guard let amount = swapAmountWei,
              amount > 0,
              let mainAddrString = mainAddress,
              let beeAddrString = try? vault.signingKey(at: .beeWallet).ethereumAddress else {
            return
        }
        isSending = true
        defer { isSending = false }

        do {
            let mainAddr = EthereumAddress(mainAddrString)
            let beeAddr = EthereumAddress(beeAddrString)
            // Fetch the spot once more right before the tx — caller may
            // have edited the input but the cached spot might be stale.
            let pool = SwarmFunderPool(walletRPC: chains.walletRPC)
            let spot = try await pool.fetchSpotXdaiPerBzz()
            spotXdaiPerBzz = spot
            let quote = SwarmFunderQuote.quote(
                xdaiForSwapWei: amount,
                spotXdaiPerBzz: spot
            )
            let (to, value, data) = try FundNodeBuilder.build(
                beeWallet: beeAddr,
                xdaiForSwap: amount,
                xdaiForBee: SwarmFunderConstants.xdaiForBeeWei,
                minBzzOut: quote.minBzzOutPlur
            )
            let txQuote = try await txService.prepare(
                from: mainAddr, to: to, valueWei: value, data: data, on: .gnosis
            )
            let hash = try await txService.send(
                to: to, valueWei: value, data: data, quote: txQuote, on: .gnosis
            )
            _ = try await txService.awaitConfirmation(hash: hash, on: .gnosis)

            // Tx confirmed — flip to light mode + restart bee. The
            // coordinator handles the stop/start dance and surfaces any
            // restart failure via the global alert.
            beeIdentity.switchMode(to: .light, swarm: swarm)
        } catch {
            sendError = error.localizedDescription
        }
    }
}
