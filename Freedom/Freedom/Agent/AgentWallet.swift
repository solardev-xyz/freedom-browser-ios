import BigInt
import Foundation
import OSLog
import SwiftUI
import web3

private let log = Logger(subsystem: "com.browser.Freedom", category: "AgentEngine")

/// One transfer the agent asks for, on screen from the first step to the
/// last: the user unlocks the wallet if it's locked, reviews the exact
/// transfer and slides to approve, or cancels. One object for every stage,
/// so the sheet stays up instead of closing and reopening between them.
@MainActor
@Observable
final class AgentTransferPrompt: Identifiable {
    enum Stage {
        case unlock
        case preparing
        case review(AgentTransferDetails)
        case sending
    }

    let id = UUID()
    /// "0.01 ETH to vitalik.eth on Ethereum", for every stage.
    let summary: String
    private(set) var stage: Stage
    @ObservationIgnored private var waiting: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private(set) var finished = false

    init(summary: String, stage: Stage) {
        self.summary = summary
        self.stage = stage
    }

    fileprivate func advance(to stage: Stage) { self.stage = stage }

    /// Waits for the user: true to go on (unlocked, approved), false when cancelled.
    fileprivate func decision() async -> Bool {
        if finished { return false }
        return await withCheckedContinuation { waiting = $0 }
    }

    /// The user went on (unlocked the wallet, slid to approve).
    func proceed() { resume(true) }

    /// The user cancelled, dismissed the sheet, or the agent's run stopped.
    func cancel() {
        finished = true
        resume(false)
    }

    private func resume(_ value: Bool) {
        let continuation = waiting
        waiting = nil
        continuation?.resume(returning: value)
    }
}

/// What the review shows and what gets signed.
struct AgentTransferDetails {
    let chain: Chain
    let token: Token
    let amount: BigUInt
    let recipient: EthereumAddress
    let recipientName: ENSReverseResolution
    let recipientNote: String?
    let from: EthereumAddress
    let walletName: String
    let txTo: EthereumAddress
    let txValue: BigUInt
    let txData: Data
    let quote: TransactionService.Quote
}

/// Desktop's `wallet_transfer` (agent-wallet-controller.js `transfer`): one
/// exact transfer from the active Freedom wallet. Freedom resolves the
/// network, asset and recipient, checks balances and estimates the fee;
/// nothing is signed until the user approves the exact transfer in
/// `AgentTransferSheet`. Signing and broadcasting are the wallet's own
/// (`TransactionService`), recorded in its activity.
@MainActor
final class AgentWalletDriver {
    enum DriverError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self { case .invalid(let message): message }
        }
    }

    private let services: WalletServices
    private let balances: WalletBalanceStore
    private let userWallets: UserWalletStore
    /// Shows the prompt (AgentService puts it on the agent's sheet) or takes it down.
    private let present: (AgentTransferPrompt?) -> Void
    private(set) var current: AgentTransferPrompt?

    init(services: WalletServices, balances: WalletBalanceStore, userWallets: UserWalletStore, present: @escaping (AgentTransferPrompt?) -> Void) {
        self.services = services
        self.balances = balances
        self.userWallets = userWallets
        self.present = present
    }

    /// One call from the engine's `wallet` service.
    func handle(_ method: String, _ params: [String: Any]) async throws -> Any? {
        switch method {
        case "transfer": return try await transfer(params)
        default: throw AgentEngine.EngineError.tool("Unknown wallet method: \(method)")
        }
    }

    /// The agent's run stopped or its engine went away: a pending transfer is cancelled.
    func cancelPending() {
        current?.cancel()
    }

    private func transfer(_ params: [String: Any]) async throws -> [String: Any] {
        guard current == nil else { throw DriverError.invalid("RESOURCE_BUSY: another wallet transfer is waiting for the user.") }
        let assetInput = (params["asset"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let amountInput = (params["amount"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let recipientInput = (params["recipient"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let chainID = (params["chainId"] as? NSNumber)?.intValue

        if let index = (params["walletIndex"] as? NSNumber)?.intValue, index != userWallets.activeIndex {
            let active = userWallets.wallets.first { $0.index == userWallets.activeIndex }
            throw DriverError.invalid("WALLET_NOT_ACTIVE: Freedom on iPhone sends from the active wallet (\(active?.name ?? "index \(userWallets.activeIndex)"), index \(userWallets.activeIndex)). Ask the user to switch wallets in Freedom, or omit walletIndex.")
        }
        guard services.vault.state != .empty else { throw DriverError.invalid("NO_WALLET: no wallet is set up in Freedom yet.") }

        let (chain, token) = try resolveAsset(assetInput, chainID: chainID)
        guard let amount = BalanceFormatter.parseAmount(amountInput, decimals: token.decimals), amount > 0 else {
            throw DriverError.invalid("INVALID_AMOUNT: \"\(amountInput)\" isn't a positive amount with at most \(token.decimals) decimals.")
        }
        let (recipient, recipientName, note) = try await resolveRecipient(recipientInput, chain: chain)
        let amountText = BalanceFormatter.format(wei: amount, token: token, maxFractionDigits: token.decimals)
        let recipientText = recipientInput.hasPrefix("0x") ? recipient.toChecksumAddress().shortenedHex() : recipientInput

        let prompt = AgentTransferPrompt(
            summary: "\(amountText) to \(recipientText) on \(chain.displayName)",
            stage: services.vault.state == .locked ? .unlock : .preparing
        )
        current = prompt
        present(prompt)
        defer {
            current = nil
            present(nil)
        }
        log.notice("[wallet] transfer asked: \(amountText, privacy: .public) on chain \(chain.id)")

        if case .unlock = prompt.stage {
            guard await prompt.decision(), services.vault.state == .unlocked else { throw Self.declined }
            prompt.advance(to: .preparing)
        }

        let details = try await prepare(chain: chain, token: token, amount: amount, recipient: recipient, recipientName: recipientName, note: note)
        prompt.advance(to: .review(details))
        guard await prompt.decision() else { throw Self.declined }

        prompt.advance(to: .sending)
        let hash: String
        do {
            hash = try await services.transactionService.send(
                to: details.txTo,
                valueWei: details.txValue,
                data: details.txData,
                quote: details.quote,
                on: chain,
                record: WalletTransactionContext(
                    kind: .walletSend,
                    toAddress: recipient.toChecksumAddress(),
                    assetAddress: token.address?.toChecksumAddress(),
                    assetSymbol: token.symbol,
                    assetDecimals: token.decimals,
                    amount: amount,
                    origin: "Freedom Agent"
                )
            )
        } catch {
            throw DriverError.invalid("BROADCAST_FAILED: \(error.localizedDescription) Nothing may have been sent; check the wallet's activity with the user before trying again.")
        }
        log.notice("[wallet] transfer sent on chain \(chain.id)")
        return [
            "status": "submitted",
            "txHash": hash,
            "chainId": chain.id,
            "network": chain.displayName,
            "from": details.from.toChecksumAddress(),
            "to": recipient.toChecksumAddress(),
            "amount": amountText,
            "explorer": chain.explorerBase.appending(path: "tx/\(hash)").absoluteString,
        ]
    }

    private static let declined = DriverError.invalid("USER_DECLINED: the user cancelled the transfer. Don't retry or work around it unless they ask again.")

    /// The asset by symbol or token contract: on `chainID`, or the one network that has it.
    private func resolveAsset(_ input: String, chainID: Int?) throws -> (Chain, Token) {
        guard !input.isEmpty else { throw DriverError.invalid("INVALID_ASSET: name the asset (a symbol like ETH or a token contract address).") }
        let chains: [Chain]
        if let chainID {
            guard let chain = services.chainStore.chain(id: chainID) else {
                throw DriverError.invalid("UNKNOWN_CHAIN: Freedom has no network with chain ID \(chainID).")
            }
            chains = [chain]
        } else {
            chains = services.chainStore.allChains()
        }
        let byAddress = Hex.isAddressShape(input)
        var matches: [(Chain, Token)] = []
        for chain in chains {
            for token in TokenRegistry.tokens(for: chain) {
                let hit = byAddress
                    ? token.address?.asString().lowercased() == input.lowercased()
                    : token.symbol.caseInsensitiveCompare(input) == .orderedSame
                if hit { matches.append((chain, token)) }
            }
        }
        if matches.count == 1 { return matches[0] }
        if matches.isEmpty {
            let scope = chainID.flatMap { services.chainStore.chain(id: $0) }.map { " on \($0.displayName)" } ?? ""
            let known = chainID.flatMap { services.chainStore.chain(id: $0) }.map { TokenRegistry.tokens(for: $0).map(\.symbol).joined(separator: ", ") }
            throw DriverError.invalid("UNKNOWN_ASSET: Freedom's wallet doesn't know \(input)\(scope).\(known.map { " Known there: \($0)." } ?? "")")
        }
        let networks = matches.map { "\($0.0.displayName) (chainId \($0.0.id))" }.joined(separator: ", ")
        throw DriverError.invalid("AMBIGUOUS_ASSET: \(input) exists on several networks: \(networks). Ask the user which network to use and retry with its chainId.")
    }

    /// A 0x address, or a name (ENS, .wei, .gwei, DNS-imported) resolved for `chain` like the Send form.
    private func resolveRecipient(_ input: String, chain: Chain) async throws -> (EthereumAddress, ENSReverseResolution, String?) {
        if Hex.isAddressShape(input) {
            let address = EthereumAddress(input)
            let name = (try? await services.ensResolver.reverseResolve(address: address, chainID: chain.id)) ?? .none
            return (address, name, nil)
        }
        guard NameSystem.isPotentialEnsName(input) else {
            throw DriverError.invalid("INVALID_RECIPIENT: \"\(input)\" is neither a 0x address nor a name like vitalik.eth.")
        }
        let resolver = services.ensResolver
        do {
            let outcome = try await RecipientNameResolution.resolve(name: input, chain: chain) { name, chainID in
                try await resolver.resolveAddress(name, chainID: chainID)
            }
            return (outcome.address, .verified(name: input), outcome.note)
        } catch {
            throw DriverError.invalid("RECIPIENT_NOT_RESOLVED: \(ENSErrorFormatting.describe(error))")
        }
    }

    /// Balances and the fee, with the vault unlocked.
    private func prepare(chain: Chain, token: Token, amount: BigUInt, recipient: EthereumAddress, recipientName: ENSReverseResolution, note: String?) async throws -> AgentTransferDetails {
        let fromHex: String
        do {
            fromHex = try services.vault.activeAddress()
        } catch {
            throw DriverError.invalid("WALLET_LOCKED: the wallet couldn't be unlocked.")
        }
        let from = EthereumAddress(fromHex)
        let native = TokenRegistry.native(for: chain)
        let known = await balances.refresh(holder: fromHex, chain: chain, tokens: token.isNative ? [native] : [native, token], minInterval: 0)
        if let held = known?[token], held < amount {
            throw DriverError.invalid("INSUFFICIENT_BALANCE: the wallet holds \(BalanceFormatter.format(wei: held, token: token)) on \(chain.displayName).")
        }
        let tx: (to: EthereumAddress, value: BigUInt, data: Data)
        do {
            tx = try TransactionService.buildSend(token: token, recipient: recipient, amount: amount)
        } catch {
            throw DriverError.invalid("The token transfer couldn't be encoded.")
        }
        let quote: TransactionService.Quote
        do {
            quote = try await services.transactionService.prepare(from: from, to: tx.to, valueWei: tx.value, data: tx.data, on: chain)
        } catch TransactionService.Error.insufficientBalance {
            throw DriverError.invalid("INSUFFICIENT_BALANCE: not enough \(chain.nativeSymbol) on \(chain.displayName) for the amount plus the network fee.")
        } catch {
            throw DriverError.invalid("FEE_ESTIMATE_FAILED: \(error.localizedDescription)")
        }
        if let nativeHeld = known?[native], nativeHeld < tx.value + quote.maxFeeWei {
            throw DriverError.invalid("INSUFFICIENT_BALANCE: the wallet holds \(BalanceFormatter.format(wei: nativeHeld, on: chain)), not enough for the amount plus the network fee (up to \(BalanceFormatter.format(wei: quote.maxFeeWei, on: chain))).")
        }
        let walletName = userWallets.wallets.first { $0.index == userWallets.activeIndex }?.name ?? UserWallet.defaultName(for: userWallets.activeIndex)
        return AgentTransferDetails(
            chain: chain, token: token, amount: amount, recipient: recipient, recipientName: recipientName,
            recipientNote: note, from: from, walletName: walletName, txTo: tx.to, txValue: tx.value, txData: tx.data, quote: quote
        )
    }
}

/// The agent's transfer, shown over the agent's sheet: unlock, review the
/// exact transfer, slide to approve (or cancel).
struct AgentTransferSheet: View {
    @Environment(Vault.self) private var vault
    let prompt: AgentTransferPrompt

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Freedom Agent wants to send").font(.caption).foregroundStyle(.secondary)
                        Text(prompt.summary).font(.headline)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    stageBody
                }
                .padding(20)
            }
            .navigationTitle("Send funds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { prompt.cancel() }
                }
            }
            .onChange(of: vault.state) { _, state in
                if state == .unlocked, case .unlock = prompt.stage { prompt.proceed() }
            }
        }
        .interactiveDismissDisabled(isSending)
    }

    private var isSending: Bool {
        if case .sending = prompt.stage { true } else { false }
    }

    @ViewBuilder private var stageBody: some View {
        switch prompt.stage {
        case .unlock:
            ApprovalUnlockStrip()
        case .preparing:
            ProgressView("Checking the balance and the fee…")
                .frame(maxWidth: .infinity)
        case .review(let details):
            review(details)
        case .sending:
            ProgressView("Sending…")
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func review(_ details: AgentTransferDetails) -> some View {
        card {
            Text("Amount").font(.caption).foregroundStyle(.secondary)
            Text(BalanceFormatter.format(wei: details.amount, token: details.token, maxFractionDigits: details.token.decimals))
                .font(.title3.weight(.semibold))
            if let address = details.token.address {
                Text("Token \(address.toChecksumAddress().shortenedHex())").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
        card {
            HStack {
                Text("To").font(.caption).foregroundStyle(.secondary)
                Spacer()
                ENSNameLabel(resolution: details.recipientName)
            }
            AddressPill(address: details.recipient.toChecksumAddress())
            if let note = details.recipientNote {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
        }
        card {
            Text("From").font(.caption).foregroundStyle(.secondary)
            Text(details.walletName).font(.callout)
            AddressPill(address: details.from.toChecksumAddress())
        }
        card {
            Text("Network").font(.caption).foregroundStyle(.secondary)
            Text(details.chain.displayName).font(.callout)
            Divider().padding(.vertical, 2)
            HStack {
                Text("Estimated fee").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(BalanceFormatter.format(wei: details.quote.maxFeeWei, on: details.chain)).font(.caption.monospaced())
            }
        }
        Text("The agent proposed this transfer. Transactions are irreversible once sent: approve only if this is exactly what you want.")
            .font(.caption)
            .foregroundStyle(.secondary)
        SlideToApprove(title: "Slide to send") { prompt.proceed() }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6, content: content)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
