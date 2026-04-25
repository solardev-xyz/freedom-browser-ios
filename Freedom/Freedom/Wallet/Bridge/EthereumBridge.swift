import Foundation
import UIKit
import WebKit
import web3

/// Per-`BrowserTab` EIP-1193 bridge. Origin identity is derived from
/// `tab.displayURL` at every message receipt — the JS side never supplies
/// it, so a page that postMessages through the handler directly still
/// only acts on permissions granted to its real display identity.
///
/// Interactive methods (connect, `personal_sign`, `eth_signTypedData_v4`;
/// tx send in WP11) short-circuit the router: they park a continuation
/// here, set `tab.pendingEthereumApproval`, and resume when the approval
/// sheet calls `decide`.
@MainActor
final class EthereumBridge: NSObject, WKScriptMessageHandler {
    static let messageHandlerName = "freedomEthereum"

    private weak var tab: BrowserTab?
    private let router: RPCRouter
    private let services: WalletServices
    // `WKUserContentController.add(_:name:)` strongly retains us, so this
    // side of the edge must be weak — otherwise BrowserTab's deinit would
    // never fire and tab-close would leak the bridge + webView + config.
    private weak var contentController: WKUserContentController?
    private var notificationTokens: [NSObjectProtocol] = []

    private var vault: Vault { services.vault }
    private var permissionStore: PermissionStore { services.permissionStore }
    private var transactionService: TransactionService { services.transactionService }

    init(
        tab: BrowserTab,
        router: RPCRouter,
        contentController: WKUserContentController,
        services: WalletServices
    ) {
        self.tab = tab
        self.router = router
        self.services = services
        self.contentController = contentController
        super.init()
        contentController.add(self, name: Self.messageHandlerName)
        installUserScript()
        subscribeToNotifications()
    }

    deinit {
        // removeObserver is thread-safe; fine to run from any isolation.
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Regenerate the EIP-6963 UUID and reinstall the preload. `removeAllUserScripts`
    /// also nukes anything else a sibling component might have added to this
    /// content controller — today nothing does; revisit if that changes.
    func reinstallForNewNavigation() {
        contentController?.removeAllUserScripts()
        installUserScript()
    }

    // MARK: - Preload

    private static let iconDataURI: String = {
        guard let image = UIImage(named: "WalletProviderIcon"),
              let data = image.pngData() else {
            assertionFailure("WalletProviderIcon asset missing or not a PNG")
            return ""
        }
        return "data:image/png;base64,\(data.base64EncodedString())"
    }()

    private static let preloadSource: String = {
        guard let url = Bundle.main.url(forResource: "EthereumBridge", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("EthereumBridge.js missing from app bundle")
            return ""
        }
        return source
    }()

    // Preamble is `<head><UUID><tail>` — only the UUID varies per navigation,
    // so head + tail are precomputed at class load. Raw string concat instead
    // of JSONSerialization because every field value is ASCII-safe (base64,
    // hyphen-hex UUID, plain ASCII name/rdns). `<` still gets escaped in the
    // tail as defense in depth, matching desktop's `</script>` mitigation.
    private static let preambleHead = #"window.__FREEDOM_PROVIDER_CONFIG__ = {"uuid":""#
    private static let preambleTail: String = {
        let raw = "\",\"name\":\"Freedom Browser\",\"icon\":\"" + iconDataURI
            + "\",\"rdns\":\"baby.freedom.browser\"};\n"
        return raw.replacingOccurrences(of: "<", with: "\\u003c")
    }()

    private func installUserScript() {
        guard let controller = contentController else { return }
        let preamble = Self.preambleHead + UUID().uuidString.lowercased() + Self.preambleTail
        let script = WKUserScript(
            source: preamble + Self.preloadSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        controller.addUserScript(script)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.messageHandlerName,
              let body = message.body as? [String: Any],
              (body["type"] as? String) == "request",
              let id = body["id"] as? Int,
              let method = body["method"] as? String else { return }
        let params = body["params"] as? [Any] ?? []
        let origin = OriginIdentity.from(displayURL: tab?.displayURL)

        Task { [weak self] in
            await self?.dispatch(id: id, method: method, params: params, origin: origin)
        }
    }

    private func dispatch(id: Int, method: String, params: [Any], origin: OriginIdentity?) async {
        guard let origin else {
            return reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.unauthorized, message: "No origin identity — cannot route request."))
        }

        switch method {
        case "eth_requestAccounts", "enable":
            await handleConnect(id: id, origin: origin)
            return
        case "personal_sign":
            await handlePersonalSign(id: id, origin: origin, params: params)
            return
        case "eth_signTypedData_v4":
            await handleTypedDataSign(id: id, origin: origin, params: params)
            return
        case "eth_sendTransaction":
            await handleSendTransaction(id: id, origin: origin, params: params)
            return
        case "wallet_switchEthereumChain":
            await handleSwitchChain(id: id, origin: origin, params: params)
            return
        default:
            break
        }

        do {
            let result = try await router.handle(method: method, params: params, origin: origin)
            reply(id: id, result: result)
        } catch {
            reply(id: id, error: router.errorPayload(for: error))
        }
    }

    // MARK: - Approval plumbing

    private func assertEligibleAndFree(id: Int, origin: OriginIdentity) -> Bool {
        guard origin.isEligibleForWallet else {
            reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.unauthorized, message: "Origin not permitted."))
            return false
        }
        guard tab?.pendingEthereumApproval == nil else {
            reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.resourceUnavailable, message: "Another approval is already pending."))
            return false
        }
        return true
    }

    private func requireConnectedOrigin(id: Int, origin: OriginIdentity) -> Bool {
        guard permissionStore.isConnected(origin.key) else {
            reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.unauthorized, message: "Connect first — \(origin.displayString) isn't authorized."))
            return false
        }
        return true
    }

    private func parkAndAwait(
        origin: OriginIdentity,
        kind: ApprovalRequest.Kind
    ) async -> ApprovalRequest.Decision {
        let decision: ApprovalRequest.Decision = await withCheckedContinuation { cont in
            let request = ApprovalRequest(
                id: UUID(),
                origin: origin,
                kind: kind,
                resolver: ApprovalResolver(cont)
            )
            tab?.pendingEthereumApproval = request
        }
        tab?.pendingEthereumApproval = nil
        return decision
    }

    // MARK: - Connect flow

    private func handleConnect(id: Int, origin: OriginIdentity) async {
        guard assertEligibleAndFree(id: id, origin: origin) else { return }

        if permissionStore.isConnected(origin.key) {
            permissionStore.touchLastUsed(origin: origin.key)
            return reply(id: id, result: permissionStore.accounts(for: origin.key))
        }

        let decision = await parkAndAwait(origin: origin, kind: .connect)
        switch decision {
        case .approved:
            do {
                let address = try vault.signingKey(at: .mainUser).ethereumAddress
                permissionStore.grant(origin: origin.key, account: address)
                emit(event: "accountsChanged", data: [address])
                emit(event: "connect", data: ["chainId": router.currentChain().hexChainID])
                reply(id: id, result: [address])
            } catch {
                reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.internalError, message: "Couldn't derive address: \(error.localizedDescription)"))
            }
        case .denied:
            reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.userRejected, message: "User rejected the request."))
        }
    }

    // MARK: - Sign flow

    private func handlePersonalSign(id: Int, origin: OriginIdentity, params: [Any]) async {
        guard assertEligibleAndFree(id: id, origin: origin),
              requireConnectedOrigin(id: id, origin: origin) else { return }

        let decoded: PersonalSignCoder.Decoded
        do {
            decoded = try PersonalSignCoder.decode(params: params)
        } catch {
            return reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.invalidParams, message: "Invalid personal_sign params."))
        }
        guard matchesGrantedAccount(decoded.declaredAddress, origin: origin) else {
            return reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.invalidParams, message: "Account in params doesn't match the connected account."))
        }

        switch await parkAndAwait(origin: origin, kind: .personalSign(decoded.preview)) {
        case .approved:
            do {
                let signature = try MessageSigner.signPersonalMessage(decoded.message, vault: vault)
                permissionStore.touchLastUsed(origin: origin.key)
                reply(id: id, result: signature)
            } catch {
                reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.internalError, message: "Signing failed: \(error.localizedDescription)"))
            }
        case .denied:
            reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.userRejected, message: "User rejected the request."))
        }
    }

    private func handleTypedDataSign(id: Int, origin: OriginIdentity, params: [Any]) async {
        guard assertEligibleAndFree(id: id, origin: origin),
              requireConnectedOrigin(id: id, origin: origin) else { return }

        guard params.count == 2, let addressParam = params.first as? String else {
            return reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.invalidParams, message: "Expected [address, typedData]."))
        }
        guard matchesGrantedAccount(addressParam, origin: origin) else {
            return reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.invalidParams, message: "Account in params doesn't match the connected account."))
        }

        let typedData: TypedData
        do {
            typedData = try decodeTypedData(params[1])
        } catch {
            return reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.invalidParams, message: "Invalid typed-data payload: \(error.localizedDescription)"))
        }

        switch await parkAndAwait(origin: origin, kind: .typedData(typedData)) {
        case .approved:
            do {
                let signature = try MessageSigner.signTypedData(typedData, vault: vault)
                permissionStore.touchLastUsed(origin: origin.key)
                reply(id: id, result: signature)
            } catch {
                reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.internalError, message: "Signing failed: \(error.localizedDescription)"))
            }
        case .denied:
            reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.userRejected, message: "User rejected the request."))
        }
    }

    private func matchesGrantedAccount(_ address: String, origin: OriginIdentity) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") else { return false }
        guard let granted = permissionStore.accounts(for: origin.key).first else { return false }
        return granted.caseInsensitiveCompare(trimmed) == .orderedSame
    }

    // MARK: - Send flow

    private func handleSendTransaction(id: Int, origin: OriginIdentity, params: [Any]) async {
        guard assertEligibleAndFree(id: id, origin: origin),
              requireConnectedOrigin(id: id, origin: origin) else { return }

        let decoded: TransactionParamsCoder.Decoded
        do {
            decoded = try TransactionParamsCoder.decode(params: params)
        } catch {
            return reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.invalidParams, message: "Invalid eth_sendTransaction params: \(error.localizedDescription)"))
        }

        guard matchesGrantedAccount(decoded.from.asString(), origin: origin) else {
            return reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.invalidParams, message: "Account in params doesn't match the connected account."))
        }

        let chain = router.currentChain()
        if let dappChain = decoded.chainID, dappChain != chain.id {
            return reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.invalidParams,
                message: "Wrong chain — wallet is on \(chain.displayName) (id \(chain.id)), tx requested chain \(dappChain). Switch first."))
        }

        let quote: TransactionService.Quote
        do {
            quote = try await composeQuote(decoded: decoded, on: chain)
        } catch {
            return reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.internalError, message: "Couldn't estimate gas: \(error.localizedDescription)"))
        }

        let details = SendTransactionDetails(
            to: decoded.to,
            valueWei: decoded.valueWei,
            data: decoded.data,
            quote: quote,
            chain: chain
        )

        switch await parkAndAwait(origin: origin, kind: .sendTransaction(details)) {
        case .approved:
            do {
                let hash = try await transactionService.send(
                    to: decoded.to,
                    valueWei: decoded.valueWei,
                    data: decoded.data,
                    quote: quote,
                    on: chain
                )
                permissionStore.touchLastUsed(origin: origin.key)
                reply(id: id, result: hash)
            } catch {
                reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.internalError, message: "Broadcast failed: \(error.localizedDescription)"))
            }
        case .denied:
            reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.userRejected, message: "User rejected the request."))
        }
    }

    // MARK: - Chain switch

    /// `wallet_switchEthereumChain` per EIP-3326. Eligibility is enough —
    /// connection isn't required (dapps commonly switch before connecting).
    /// Already-on-this-chain returns silent `null`. Unknown chain returns
    /// `4902` so the dapp can surface "add chain first" UX (we don't
    /// implement `wallet_addEthereumChain` in v1 — see §6.4).
    private func handleSwitchChain(id: Int, origin: OriginIdentity, params: [Any]) async {
        guard assertEligibleAndFree(id: id, origin: origin) else { return }

        let requestedID: Int
        do {
            requestedID = try SwitchChainParamsCoder.decodeChainID(params: params)
        } catch {
            return reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.invalidParams, message: "Expected [{chainId: hex}]."))
        }

        let current = router.currentChain()
        if current.id == requestedID {
            return reply(id: id, result: NSNull())
        }

        guard let target = Chain.find(id: requestedID) else {
            return reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.unrecognizedChain, message: "Unrecognized chain ID. Add it first."))
        }

        let details = SwitchChainDetails(from: current, to: target)
        switch await parkAndAwait(origin: origin, kind: .switchChain(details)) {
        case .approved:
            WalletDefaults.setActiveChainID(target.id)
            reply(id: id, result: NSNull())
        case .denied:
            reply(id: id, error: .init(code: RPCRouter.ErrorPayload.Code.userRejected, message: "User rejected the request."))
        }
    }

    /// Skip the 3-RPC `prepare` call when the dapp supplied every override
    /// (common for established dapps that compute their own gas). Partial
    /// overrides still go through prepare and patch the missing slots.
    private func composeQuote(
        decoded: TransactionParamsCoder.Decoded,
        on chain: Chain
    ) async throws -> TransactionService.Quote {
        if let nonce = decoded.nonce,
           let gasPrice = decoded.gasPriceWei,
           let gasLimit = decoded.gasLimit {
            return TransactionService.Quote(
                from: decoded.from, nonce: nonce, gasPrice: gasPrice, gasLimit: gasLimit
            )
        }
        let estimated = try await transactionService.prepare(
            from: decoded.from,
            to: decoded.to,
            valueWei: decoded.valueWei,
            data: decoded.data,
            on: chain
        )
        return TransactionService.Quote(
            from: decoded.from,
            nonce: decoded.nonce ?? estimated.nonce,
            gasPrice: decoded.gasPriceWei ?? estimated.gasPrice,
            gasLimit: decoded.gasLimit ?? estimated.gasLimit
        )
    }

    /// Dapps pass `typedData` either as a JSON string or as a JSON object —
    /// decode both via JSONSerialization, then through the typed decoder.
    private func decodeTypedData(_ param: Any) throws -> TypedData {
        let data: Data
        if let string = param as? String {
            data = Data(string.utf8)
        } else if let object = param as? [String: Any] {
            data = try JSONSerialization.data(withJSONObject: object)
        } else {
            throw PersonalSignCoder.Error.badParams
        }
        return try JSONDecoder().decode(TypedData.self, from: data)
    }

    // MARK: - Event emission

    private func emit(event: String, data: Any) {
        guard let webView = tab?.webView else { return }
        let js = "window.__freedomEthereum && window.__freedomEthereum.__handleEvent(\(jsonLiteral(event)), \(jsonLiteral(data)));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func subscribeToNotifications() {
        let center = NotificationCenter.default
        let chainToken = center.addObserver(
            forName: .walletActiveChainChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.emitChainChangedIfConnected(note) }
        }
        let revokeToken = center.addObserver(
            forName: .walletPermissionRevoked,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.emitDisconnectIfMatch(note) }
        }
        notificationTokens = [chainToken, revokeToken]
    }

    private func emitChainChangedIfConnected(_ note: Notification) {
        guard let origin = OriginIdentity.from(displayURL: tab?.displayURL),
              permissionStore.isConnected(origin.key),
              let chainID = note.userInfo?["chainID"] as? Int else { return }
        emit(event: "chainChanged", data: "0x" + String(chainID, radix: 16))
    }

    private func emitDisconnectIfMatch(_ note: Notification) {
        guard let origin = OriginIdentity.from(displayURL: tab?.displayURL),
              let revokedOrigin = note.userInfo?["origin"] as? String,
              origin.key == revokedOrigin else { return }
        emit(event: "accountsChanged", data: [String]())
        emit(event: "disconnect", data: NSNull())
    }

    // MARK: - Reply path

    private func reply(id: Int, result: Any) {
        evaluateResponse(id: id, resultJSON: jsonLiteral(result), errorJSON: "null")
    }

    private func reply(id: Int, error: RPCRouter.ErrorPayload) {
        let errJSON = jsonLiteral(["code": error.code, "message": error.message])
        evaluateResponse(id: id, resultJSON: "null", errorJSON: errJSON)
    }

    private func evaluateResponse(id: Int, resultJSON: String, errorJSON: String) {
        guard let webView = tab?.webView else { return }
        let js = "window.__freedomEthereum && window.__freedomEthereum.__handleResponse(\(id), \(resultJSON), \(errorJSON));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// JSONSerialization quotes + escapes strings, so direct interpolation
    /// into evaluateJavaScript is injection-safe. Returns "null" on failure.
    private func jsonLiteral(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let string = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return string
    }
}
