import BigInt
import Foundation
import web3

/// Wallet endpoint for one openlv remote-signing session: the desktop
/// browser shows a QR, the user scans (or pastes) it here, and the
/// browser's JSON-RPC requests flow through the engine into the same
/// approval sheets and signers the in-app dapp bridge uses.
///
/// Deliberately NOT built on `EthereumBridge`/`PermissionStore`: dapp
/// permissions are origin-scoped and persistent, while an openlv
/// session is user-initiated (they scanned this QR seconds ago),
/// short-lived, and per-request — every signing request gets its own
/// approval sheet, and no grant or secret outlives the session. (An
/// approved chain switch does persist: it is the wallet's chain, same
/// semantics as the dapp bridge — see handleSwitchChain.) The shared
/// pieces are the param coders, `MessageSigner`, `TransactionService`,
/// and the approval sheets themselves.
@MainActor
@Observable
final class OpenLVWalletSession {
    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case disconnected
        case failed(String)
    }

    /// Identity shown on approval sheets. Never persisted — the session
    /// keeps no grants, so this key never reaches a permission store.
    static let origin = OriginIdentity(key: "openlv://remote", scheme: .openlv)

    private(set) var status: Status = .idle
    /// Parked approval, presented as a sheet by ContentView — same
    /// contract as `BrowserTab.pendingEthereumApproval`.
    private(set) var pendingApproval: ApprovalRequest?

    private let services: WalletServices
    private let activeChain: @MainActor () -> Chain
    private let engineFactory: @MainActor () -> OpenLVSessionEngine
    private var engine: OpenLVSessionEngine?
    /// Set once the user approves eth_requestAccounts; cleared when the
    /// session ends. Lets eth_accounts answer without a second sheet.
    private var sessionAccount: String?

    init(
        services: WalletServices,
        activeChain: @escaping @MainActor () -> Chain,
        engineFactory: @escaping @MainActor () -> OpenLVSessionEngine = { WebViewOpenLVEngine() }
    ) {
        self.services = services
        self.activeChain = activeChain
        self.engineFactory = engineFactory
    }

    var isActive: Bool {
        status == .connecting || status == .connected
    }

    // MARK: - Lifecycle

    /// Accepts what a user can actually produce: the raw `openlv://` URI
    /// or the full bridge URL from the QR (`https://…/#openlv://…`).
    /// The fragment is percent-decoded once, mirroring the bridge page.
    static func extractOpenLVURI(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("openlv://") { return trimmed }
        guard let hashIndex = trimmed.firstIndex(of: "#") else { return nil }
        let fragment = String(trimmed[trimmed.index(after: hashIndex)...])
        let decoded = fragment.removingPercentEncoding ?? fragment
        return decoded.lowercased().hasPrefix("openlv://") ? decoded : nil
    }

    func start(uri: String) async throws {
        let engine = self.engine ?? engineFactory()
        self.engine = engine
        engine.requestHandler = { [weak self] method, params in
            await self?.handleRequest(method: method, params: params)
                ?? .error(code: -32603, message: "Session closed.")
        }
        engine.statusHandler = { [weak self] engineStatus in
            self?.apply(engineStatus)
        }
        status = .connecting
        do {
            try await engine.start(uri: uri)
        } catch {
            // Own the state machine on boot failure — callers (paste UI,
            // deep link) surface errors differently, but none should be
            // able to leave the session stuck on `.connecting`.
            status = .failed("Couldn't start the session runtime.")
            throw error
        }
    }

    func stop() {
        engine?.stop()
        resolvePendingApproval(.denied)
        sessionAccount = nil
        status = .idle
    }

    /// Single point that resumes a parked continuation from any sheet
    /// dismissal path (button or swipe) — mirrors `BrowserTab`.
    func resolvePendingApproval(_ decision: ApprovalRequest.Decision) {
        let pending = pendingApproval
        pendingApproval = nil
        pending?.decide(decision)
    }

    private func apply(_ engineStatus: OpenLVEngineStatus) {
        switch engineStatus {
        case .connecting: status = .connecting
        case .connected: status = .connected
        case .disconnected:
            sessionAccount = nil
            status = .disconnected
        case .failed(let message): status = .failed(message)
        }
    }

    // MARK: - Request dispatch

    /// Internal so tests can drive it without an engine. Every response
    /// is the wire envelope the desktop's remote signer unwraps —
    /// EIP-1193 codes matter (4001 user-reject, 4902 unknown chain).
    func handleRequest(method: String, params: [Any]) async -> OpenLVResponse {
        switch method {
        case "eth_chainId":
            return .result(activeChain().hexChainID)
        case "eth_accounts":
            return .result(sessionAccount.map { [$0] } ?? [String]())
        case "eth_requestAccounts":
            return await gated { await self.handleRequestAccounts() }
        case "personal_sign":
            return await gated { await self.handlePersonalSign(params: params) }
        case "eth_signTypedData_v4":
            return await gated { await self.handleTypedData(params: params) }
        case "eth_sendTransaction":
            return await gated { await self.handleSendTransaction(params: params) }
        case "wallet_switchEthereumChain":
            return await gated { await self.handleSwitchChain(params: params) }
        default:
            // Includes wallet_addEthereumChain: the chain registry is
            // user-managed (Settings → Chainlist search); the desktop
            // surfaces this message when a pre-flight add fails.
            return .error(
                code: RPCRouter.ErrorPayload.Code.unsupportedMethod,
                message: "Method not supported: \(method). Add missing chains in Freedom's settings."
            )
        }
    }

    /// One approval at a time, like the dapp bridge.
    private func gated(_ body: () async -> OpenLVResponse) async -> OpenLVResponse {
        guard pendingApproval == nil else {
            return .error(
                code: RPCRouter.ErrorPayload.Code.resourceUnavailable,
                message: "Another approval is already pending."
            )
        }
        return await body()
    }

    private func parkAndAwait(kind: ApprovalRequest.Kind) async -> ApprovalRequest.Decision {
        let decision: ApprovalRequest.Decision = await withCheckedContinuation { cont in
            pendingApproval = ApprovalRequest(
                id: UUID(),
                origin: Self.origin,
                kind: kind,
                resolver: ApprovalResolver(cont)
            )
        }
        pendingApproval = nil
        return decision
    }

    private static let rejected = OpenLVResponse.error(
        code: RPCRouter.ErrorPayload.Code.userRejected,
        message: "User rejected the request."
    )

    /// Main-user address. Only callable after an approval — the sheets
    /// gate their approve button on vault unlock (`ApprovalUnlockStrip`).
    private func vaultAddress() throws -> String {
        try services.vault.signingKey(at: .mainUser).ethereumAddress
    }

    private func matchesVaultAccount(_ declared: String) -> Bool {
        guard let address = try? vaultAddress() else { return false }
        return address.caseInsensitiveCompare(
            declared.trimmingCharacters(in: .whitespacesAndNewlines)
        ) == .orderedSame
    }

    // MARK: - Handlers

    private func handleRequestAccounts() async -> OpenLVResponse {
        if let sessionAccount { return .result([sessionAccount]) }
        switch await parkAndAwait(kind: .connect) {
        case .approved:
            do {
                let address = try vaultAddress()
                sessionAccount = address
                return .result([address])
            } catch {
                return .error(
                    code: RPCRouter.ErrorPayload.Code.internalError,
                    message: "Couldn't derive address: \(error.localizedDescription)"
                )
            }
        case .denied:
            return Self.rejected
        }
    }

    // Sign/send handlers deliberately have NO connect-first gate (the
    // tab bridge's requireConnectedOrigin): desktop signing jobs run in
    // their own per-request session and never send eth_requestAccounts
    // first — the account was captured in an earlier connect session.
    // Consent comes from the user having scanned this QR plus the
    // per-request sheet; matchesVaultAccount pins the signer.

    private func handlePersonalSign(params: [Any]) async -> OpenLVResponse {
        let decoded: PersonalSignCoder.Decoded
        do {
            decoded = try PersonalSignCoder.decode(params: params)
        } catch {
            return .error(
                code: RPCRouter.ErrorPayload.Code.invalidParams,
                message: "Invalid personal_sign params."
            )
        }

        switch await parkAndAwait(kind: .personalSign(decoded.preview)) {
        case .approved:
            // Account check runs post-approval: the vault may be locked
            // until the sheet's unlock strip runs. The desktop verifies
            // the recovered signer independently either way.
            guard matchesVaultAccount(decoded.declaredAddress) else {
                return .error(
                    code: RPCRouter.ErrorPayload.Code.invalidParams,
                    message: "Account in params doesn't match this wallet."
                )
            }
            do {
                let signature = try MessageSigner.signPersonalMessage(decoded.message, vault: services.vault)
                return .result(signature)
            } catch {
                return .error(
                    code: RPCRouter.ErrorPayload.Code.internalError,
                    message: "Signing failed: \(error.localizedDescription)"
                )
            }
        case .denied:
            return Self.rejected
        }
    }

    private func handleTypedData(params: [Any]) async -> OpenLVResponse {
        guard params.count == 2, let addressParam = params.first as? String else {
            return .error(
                code: RPCRouter.ErrorPayload.Code.invalidParams,
                message: "Expected [address, typedData]."
            )
        }
        let typedData: TypedData
        do {
            typedData = try TypedDataCoder.decode(params[1])
        } catch {
            return .error(
                code: RPCRouter.ErrorPayload.Code.invalidParams,
                message: "Invalid typed-data payload: \(error.localizedDescription)"
            )
        }

        switch await parkAndAwait(kind: .typedData(typedData)) {
        case .approved:
            guard matchesVaultAccount(addressParam) else {
                return .error(
                    code: RPCRouter.ErrorPayload.Code.invalidParams,
                    message: "Account in params doesn't match this wallet."
                )
            }
            do {
                let signature = try MessageSigner.signTypedData(typedData, vault: services.vault)
                return .result(signature)
            } catch {
                return .error(
                    code: RPCRouter.ErrorPayload.Code.internalError,
                    message: "Signing failed: \(error.localizedDescription)"
                )
            }
        case .denied:
            return Self.rejected
        }
    }

    private func handleSendTransaction(params: [Any]) async -> OpenLVResponse {
        let decoded: TransactionParamsCoder.Decoded
        do {
            decoded = try TransactionParamsCoder.decode(params: params)
        } catch {
            return .error(
                code: RPCRouter.ErrorPayload.Code.invalidParams,
                message: "Invalid eth_sendTransaction params: \(error.localizedDescription)"
            )
        }

        let chain = activeChain()
        if let requestChain = decoded.chainID, requestChain != chain.id {
            return .error(
                code: RPCRouter.ErrorPayload.Code.invalidParams,
                message: "Wrong chain — wallet is on \(chain.displayName) (id \(chain.id)), tx requested chain \(requestChain). Switch first."
            )
        }

        let quote: TransactionService.Quote
        do {
            quote = try await services.transactionService.quote(for: decoded, on: chain)
        } catch {
            return .error(
                code: RPCRouter.ErrorPayload.Code.internalError,
                message: "Couldn't estimate gas: \(error.localizedDescription)"
            )
        }

        let details = SendTransactionDetails(
            to: decoded.to,
            valueWei: decoded.valueWei,
            data: decoded.data,
            quote: quote,
            chain: chain
        )

        switch await parkAndAwait(kind: .sendTransaction(details)) {
        case .approved:
            guard matchesVaultAccount(decoded.from.asString()) else {
                return .error(
                    code: RPCRouter.ErrorPayload.Code.invalidParams,
                    message: "Account in params doesn't match this wallet."
                )
            }
            do {
                let hash = try await services.transactionService.send(
                    to: decoded.to,
                    valueWei: decoded.valueWei,
                    data: decoded.data,
                    quote: quote,
                    on: chain
                )
                return .result(hash)
            } catch {
                return .error(
                    code: RPCRouter.ErrorPayload.Code.internalError,
                    message: "Broadcast failed: \(error.localizedDescription)"
                )
            }
        case .denied:
            return Self.rejected
        }
    }

    private func handleSwitchChain(params: [Any]) async -> OpenLVResponse {
        let requestedID: Int
        do {
            requestedID = try SwitchChainParamsCoder.decodeChainID(params: params)
        } catch {
            return .error(
                code: RPCRouter.ErrorPayload.Code.invalidParams,
                message: "Expected [{chainId: hex}]."
            )
        }

        let current = activeChain()
        if current.id == requestedID {
            return .result(NSNull())
        }
        guard let target = services.chainStore.chain(id: requestedID) else {
            return .error(
                code: RPCRouter.ErrorPayload.Code.unrecognizedChain,
                message: "Unrecognized chain ID. Add it in Freedom's settings first."
            )
        }

        switch await parkAndAwait(kind: .switchChain(SwitchChainDetails(from: current, to: target))) {
        case .approved:
            // Same global chain semantics as the dapp bridge and every
            // phone wallet's WalletConnect flow: the approved switch is
            // the wallet's chain, and it outlives the session. The sheet
            // told the user exactly what they were switching.
            WalletDefaults.setActiveChainID(target.id)
            return .result(NSNull())
        case .denied:
            return Self.rejected
        }
    }
}
