import Foundation
import UIKit
import WebKit

/// Per-`BrowserTab` EIP-1193 bridge. Origin identity is derived from
/// `tab.displayURL` at every message receipt — the JS side never supplies
/// it, so a page that postMessages through the handler directly still
/// only acts on permissions granted to its real display identity.
@MainActor
final class EthereumBridge: NSObject, WKScriptMessageHandler {
    static let messageHandlerName = "freedomEthereum"

    private weak var tab: BrowserTab?
    private let router: RPCRouter
    // `WKUserContentController.add(_:name:)` strongly retains us, so this
    // side of the edge must be weak — otherwise BrowserTab's deinit would
    // never fire and tab-close would leak the bridge + webView + config.
    private weak var contentController: WKUserContentController?

    init(tab: BrowserTab, router: RPCRouter, contentController: WKUserContentController) {
        self.tab = tab
        self.router = router
        self.contentController = contentController
        super.init()
        contentController.add(self, name: Self.messageHandlerName)
        installUserScript()
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
        do {
            let result = try await router.handle(method: method, params: params, origin: origin)
            reply(id: id, result: result)
        } catch {
            reply(id: id, error: router.errorPayload(for: error))
        }
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
