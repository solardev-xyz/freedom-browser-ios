import BigInt
import Foundation
import OSLog
import SwiftUI
import web3

private let log = Logger(subsystem: "com.browser.Freedom", category: "AgentEngine")

/// One domain transaction waiting for the user (desktop's wallet approval
/// card for domain_execute): unlock if locked, review the exact transaction,
/// slide to approve; then it stays up while the engine rechecks the plan,
/// journals it and the app sends it.
@MainActor
@Observable
final class AgentDomainPrompt: Identifiable {
    enum Stage {
        case unlock
        case review
        case sending
    }

    struct Item: Hashable {
        let label: String
        let value: String
    }

    let id = UUID()
    /// "Commit registration of example.gwei".
    let title: String
    let items: [Item]
    let contractName: String?
    let to: String
    let account: String
    let accountName: String
    let value: String
    let maxFee: String
    let data: String
    private(set) var stage: Stage
    @ObservationIgnored private var waiting: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private(set) var finished = false

    init(params: [String: Any], locked: Bool) {
        title = params["label"] as? String ?? "Domain transaction"
        let presentation = params["presentation"] as? [String: Any] ?? [:]
        items = (presentation["items"] as? [[String: Any]] ?? []).compactMap { item in
            guard let label = item["label"] as? String, let value = item["value"] as? String else { return nil }
            return Item(label: label, value: value)
        }
        let contract = presentation["contract"] as? [String: Any]
        to = params["to"] as? String ?? ""
        // The contract's name only when it is the address the transaction goes to (desktop).
        contractName = (contract?["address"] as? String)?.lowercased() == to.lowercased() ? contract?["name"] as? String : nil
        let accountInfo = params["account"] as? [String: Any] ?? [:]
        account = accountInfo["address"] as? String ?? ""
        accountName = accountInfo["name"] as? String ?? "Wallet"
        value = params["value"] as? String ?? ""
        maxFee = params["maxFee"] as? String ?? ""
        data = params["data"] as? String ?? ""
        stage = locked ? .unlock : .review
    }

    fileprivate func advance(to stage: Stage) { self.stage = stage }

    fileprivate func decision() async -> Bool {
        if finished { return false }
        return await withCheckedContinuation { waiting = $0 }
    }

    func proceed() { resume(true) }

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

/// The engine's `domains` service (AgentEngine/src/domains, desktop's domain
/// service): Ethereum mainnet reads through Freedom's chain-data router, the
/// operation journal and registration secrets, the active wallet, the
/// approval sheet and the send, and Freedom's own name resolution. The engine
/// builds and checks every transaction; this side never takes calldata from
/// the model, only the plan the engine's service encoded.
@MainActor
final class AgentDomainDriver {
    struct DriverError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let services: WalletServices
    private let userWallets: UserWalletStore
    private let present: (AgentDomainPrompt?) -> Void
    private(set) var current: AgentDomainPrompt?
    private var quotes: [String: (to: EthereumAddress, value: BigUInt, data: Data, quote: TransactionService.Quote, prompt: AgentDomainPrompt?)] = [:]

    private static let secretService = "com.browser.Freedom.agent.domain-secret"
    private static var journal: URL { AgentDatabase.directory.appending(path: "domain-operations.json") }

    init(services: WalletServices, userWallets: UserWalletStore, present: @escaping (AgentDomainPrompt?) -> Void) {
        self.services = services
        self.userWallets = userWallets
        self.present = present
    }

    func handle(_ method: String, _ params: [String: Any]) async throws -> Any? {
        switch method {
        case "rpc":
            guard let rpcMethod = params["method"] as? String, Self.readMethods.contains(rpcMethod) else {
                throw DriverError(message: "Unsupported chain request.")
            }
            return try await services.chainRegistry.walletRPC.callJSON(method: rpcMethod, params: params["params"] as? [Any] ?? [], on: .mainnet)
        case "account": return try account()
        case "ownWallet": return ownWallet(params["address"] as? String ?? "")
        case "balance":
            let address = params["address"] as? String ?? ""
            let hex = try await services.chainRegistry.walletRPC.balance(of: address, on: .mainnet)
            return ["balanceWei": (Hex.bigUInt(hex) ?? 0).description]
        case "loadOperations":
            guard let data = try? Data(contentsOf: Self.journal) else { return ["operations": [Any]()] }
            return try JSONSerialization.jsonObject(with: data)
        case "saveOperations":
            guard let body = params["body"] as? String else { throw DriverError(message: "No journal.") }
            try FileManager.default.createDirectory(at: AgentDatabase.directory, withIntermediateDirectories: true)
            try Data(body.utf8).write(to: Self.journal, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        case "saveSecret":
            guard let handle = params["handle"] as? String, let secret = params["secret"] as? String else { throw DriverError(message: "No secret.") }
            try KeychainItem(account: handle, service: Self.secretService).write(Data(secret.utf8), protection: .deviceOnly)
            return true
        case "readSecret":
            guard let handle = params["handle"] as? String,
                  let data = try KeychainItem(account: handle, service: Self.secretService).read() else { return ["secret": NSNull()] }
            return ["secret": String(decoding: data, as: UTF8.self)]
        case "deleteSecret":
            if let handle = params["handle"] as? String { try? KeychainItem(account: handle, service: Self.secretService).delete() }
            return true
        case "quote": return try await quote(params)
        case "approve": return await approve(params)
        case "send": return try await send(params)
        case "finish":
            if let id = params["quoteId"] as? String, let entry = quotes.removeValue(forKey: id), let prompt = entry.prompt, prompt === current {
                current = nil
                present(nil)
            }
            return true
        case "verifyResolution": return await verifyResolution(params)
        default:
            throw AgentEngine.EngineError.tool("Unknown domains method: \(method)")
        }
    }

    /// Reads only: the service's snapshot, contract calls, code checks and receipts.
    private static let readMethods: Set<String> = [
        "eth_getBlockByNumber", "eth_call", "eth_getCode", "eth_getTransactionReceipt",
        "eth_getTransactionByHash", "eth_getTransactionCount", "eth_blockNumber",
    ]

    /// The agent's run stopped or its engine went away.
    func cancelPending() {
        current?.cancel()
    }

    private func account() throws -> [String: Any] {
        guard services.vault.state != .empty else { return ["message": "No wallet is set up in Freedom yet."] }
        let index = userWallets.activeIndex
        let name = userWallets.wallets.first { $0.index == index }?.name ?? UserWallet.defaultName(for: index)
        guard let address = try? services.vault.activeAddress() else {
            return ["message": "Freedom’s wallet is locked. Ask the user to unlock it, then try again."]
        }
        return ["index": index, "address": address, "name": name]
    }

    private func ownWallet(_ address: String) -> [String: Any] {
        if let own = try? services.vault.activeAddress(), own.lowercased() == address.lowercased() {
            let index = userWallets.activeIndex
            return ["status": "own", "index": index, "name": userWallets.wallets.first { $0.index == index }?.name ?? UserWallet.defaultName(for: index)]
        }
        // Other wallets' addresses need the vault's other paths; without them this is unknown.
        return ["status": userWallets.wallets.count > 1 ? "unknown" : "other"]
    }

    /// Gas (+20%, as desktop) and the fee for the exact plan, kept until `finish`.
    private func quote(_ params: [String: Any]) async throws -> [String: Any] {
        guard let from = params["from"] as? String, let toHex = params["to"] as? String,
              let dataHex = params["data"] as? String, let data = Data(hex: dataHex),
              let value = BigUInt(params["value"] as? String ?? "") else { throw DriverError(message: "Incomplete plan.") }
        let to = EthereumAddress(toHex)
        let estimated = try await services.transactionService.prepare(from: EthereumAddress(from), to: to, valueWei: value, data: data, on: .mainnet)
        let quote = TransactionService.Quote(
            from: estimated.from, nonce: estimated.nonce, gasPrice: estimated.gasPrice,
            gasLimit: estimated.gasLimit * 120 / 100
        )
        let id = UUID().uuidString
        quotes[id] = (to, value, data, quote, nil)
        return ["quoteId": id, "maxFeeWei": quote.maxFeeWei.description]
    }

    private func approve(_ params: [String: Any]) async -> [String: Any] {
        guard let id = params["quoteId"] as? String, quotes[id] != nil, current == nil else { return ["status": "declined"] }
        let prompt = AgentDomainPrompt(params: params, locked: services.vault.state == .locked)
        quotes[id]?.prompt = prompt
        current = prompt
        present(prompt)
        log.notice("[domains] approval asked: \(prompt.title, privacy: .public)")
        #if DEBUG
        // FREEDOM_DEBUG_AGENT_DOMAIN=decline: the sheet is declined after 5 s (simulator runs; never approves).
        if ProcessInfo.processInfo.environment["FREEDOM_DEBUG_AGENT_DOMAIN"] == "decline" {
            Task {
                try? await Task.sleep(for: .seconds(5))
                prompt.cancel()
            }
        }
        #endif
        if case .unlock = prompt.stage {
            guard await prompt.decision(), services.vault.state == .unlocked else { return ["status": "declined"] }
            prompt.advance(to: .review)
        }
        guard await prompt.decision() else {
            log.notice("[domains] declined: \(prompt.title, privacy: .public)")
            return ["status": "declined"]
        }
        prompt.advance(to: .sending)
        log.notice("[domains] approved: \(prompt.title, privacy: .public)")
        return ["status": "approved"]
    }

    /// Signs with the approved account only, then broadcasts. `notBroadcast` when
    /// nothing left the phone (locked vault, another wallet active, signing failed);
    /// a thrown error otherwise, which the engine treats as maybe sent.
    private func send(_ params: [String: Any]) async throws -> [String: Any] {
        guard let id = params["quoteId"] as? String, let entry = quotes[id], entry.prompt?.finished == false else {
            return ["notBroadcast": true]
        }
        guard let active = try? services.vault.activeAddress(), active.lowercased() == entry.quote.from.asString().lowercased() else {
            return ["notBroadcast": true]
        }
        do {
            let hash = try await services.transactionService.send(
                to: entry.to, valueWei: entry.value, data: entry.data, quote: entry.quote, on: .mainnet,
                record: WalletTransactionContext(
                    kind: .dappSend, toAddress: entry.to.toChecksumAddress(), assetAddress: nil, assetSymbol: "ETH",
                    assetDecimals: 18, amount: entry.value, origin: "Freedom Agent"
                )
            )
            log.notice("[domains] sent \(entry.prompt?.title ?? "", privacy: .public)")
            return ["hash": hash]
        } catch TransactionService.Error.signingFailed, TransactionService.Error.broadcastMalformed {
            return ["notBroadcast": true]
        } catch is Vault.Error {
            return ["notBroadcast": true]
        }
    }

    /// Freedom's own resolution of `name` points at `bzz://reference` (after a website write).
    private func verifyResolution(_ params: [String: Any]) async -> [String: Any] {
        guard let name = params["name"] as? String, let reference = (params["reference"] as? String)?.lowercased() else { return ["verified": false] }
        services.ensResolver.invalidate()
        let resolved = try? await services.ensResolver.resolveContent(name)
        return ["verified": resolved?.uri.scheme == "bzz" && resolved?.contentRef.lowercased() == reference]
    }
}

// MARK: - Sheet

/// The approval for one domain transaction, over the agent's sheet: desktop's
/// domain card (name, step, term, price, records), the contract, account,
/// amount and maximum fee, the exact contract data, then slide to approve.
struct AgentDomainSheet: View {
    @Environment(Vault.self) private var vault
    let prompt: AgentDomainPrompt

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Freedom Agent asks for this transaction").font(.caption).foregroundStyle(.secondary)
                        Text(prompt.title).font(.headline)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    stageBody
                }
                .padding(20)
            }
            .navigationTitle("Domain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { prompt.cancel() }
                        .disabled(isSending)
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
        case .review:
            review
        case .sending:
            ProgressView("Checking the plan again and sending…")
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var review: some View {
        card {
            ForEach(prompt.items, id: \.self) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label).font(.caption).foregroundStyle(.secondary)
                    Text(item.value).font(.callout).textSelection(.enabled)
                }
            }
        }
        card {
            Text("To").font(.caption).foregroundStyle(.secondary)
            if let name = prompt.contractName { Text(name).font(.callout) }
            AddressPill(address: prompt.to)
            Divider().padding(.vertical, 2)
            Text("Account").font(.caption).foregroundStyle(.secondary)
            Text(prompt.accountName).font(.callout)
            AddressPill(address: prompt.account)
        }
        card {
            HStack {
                Text("Amount").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(prompt.value).font(.callout.monospaced())
            }
            HStack {
                Text("Maximum network fee").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(prompt.maxFee).font(.caption.monospaced())
            }
            Text("Ethereum").font(.caption2).foregroundStyle(.secondary)
        }
        DisclosureGroup("Contract data") {
            Text(prompt.data).font(.caption2.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.footnote)
        Text("Prepared by Freedom from Agent’s domain request. The exact transaction above is held until you decide; transactions can't be undone once sent.")
            .font(.caption)
            .foregroundStyle(.secondary)
        SlideToApprove(title: "Slide to approve") { prompt.proceed() }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6, content: content)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
