import Foundation
import UIKit
import WebKit

/// Per-`BrowserTab` EIP-1193 bridge. Origin identity is derived from
/// `tab.displayURL` at every message receipt — the JS side never supplies
/// it, so a page that postMessages through the handler directly still
/// only acts on permissions granted to its real display identity.
///
/// Interactive methods (`eth_requestAccounts` today; signing/send in
/// WP10/WP11) short-circuit the router: they park a continuation here,
/// set `tab.pendingEthereumApproval`, and resume when the approval sheet
/// calls `decide`.
@MainActor
final class EthereumBridge: NSObject, WKScriptMessageHandler {
    static let messageHandlerName = "freedomEthereum"

    private weak var tab: BrowserTab?
    private let router: RPCRouter
    private let vault: Vault
    private let permissionStore: PermissionStore
    // `WKUserContentController.add(_:name:)` strongly retains us, so this
    // side of the edge must be weak — otherwise BrowserTab's deinit would
    // never fire and tab-close would leak the bridge + webView + config.
    private weak var contentController: WKUserContentController?
    private var notificationTokens: [NSObjectProtocol] = []

    init(
        tab: BrowserTab,
        router: RPCRouter,
        contentController: WKUserContentController,
        vault: Vault,
        permissionStore: PermissionStore
    ) {
        self.tab = tab
        self.router = router
        self.vault = vault
        self.permissionStore = permissionStore
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
            return reply(id: id, error: .init(code: 4100, message: "No origin identity — cannot route request."))
        }

        switch method {
        case "eth_requestAccounts", "enable":
            await handleConnect(id: id, origin: origin)
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

    // MARK: - Connect flow

    private func handleConnect(id: Int, origin: OriginIdentity) async {
        guard origin.isEligibleForWallet else {
            return reply(id: id, error: .init(code: 4100, message: "Origin not permitted."))
        }

        if permissionStore.isConnected(origin.key) {
            permissionStore.touchLastUsed(origin: origin.key)
            return reply(id: id, result: permissionStore.accounts(for: origin.key))
        }

        // Prevent concurrent approval races on a single tab. -32002 is
        // EIP-1474's "resource unavailable" — MetaMask uses the same.
        guard tab?.pendingEthereumApproval == nil else {
            return reply(id: id, error: .init(code: -32002, message: "Another approval is already pending."))
        }

        let decision: ApprovalRequest.Decision = await withCheckedContinuation { cont in
            let request = ApprovalRequest(
                id: UUID(),
                origin: origin,
                kind: .connect,
                resolver: ApprovalResolver(cont)
            )
            tab?.pendingEthereumApproval = request
        }
        tab?.pendingEthereumApproval = nil

        switch decision {
        case .approved(let account):
            permissionStore.grant(origin: origin.key, account: account)
            emit(event: "accountsChanged", data: [account])
            emit(event: "connect", data: ["chainId": router.currentChainHex()])
            reply(id: id, result: [account])
        case .denied:
            reply(id: id, error: .init(code: 4001, message: "User rejected the request."))
        }
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
