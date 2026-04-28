import Foundation
import WebKit

/// Shared `id → reply` + event-emit transport for `EthereumBridge` and
/// `SwarmBridge`. The two bridges produce different error envelopes
/// (`SwarmBridge` carries an optional `data.reason`; `EthereumBridge`
/// doesn't), so the channel takes a pre-built dict for errors and only
/// owns JSON encoding + `evaluateJavaScript` dispatch. Lives in
/// `Wallet/Bridge/` next to `OriginIdentity` — same cross-cutting
/// precedent.
///
/// `jsGlobal` is the unprefixed JS-side global name
/// (`__freedomEthereum` / `__freedomSwarm`). The page's preload script
/// installs a `__handleResponse(id, result, error)` and
/// `__handleEvent(name, data)` on that global; this class produces
/// matching `evaluateJavaScript` calls.
@MainActor
final class BridgeReplyChannel {
    private let jsGlobal: String
    /// Weak: the channel is owned by the bridge, the bridge weak-refs
    /// `BrowserTab` (so the WKUserContentController retain doesn't keep
    /// the tab alive). Mirroring weak-ness here keeps the channel from
    /// extending the webView's life past tab teardown.
    private weak var webView: WKWebView?

    init(jsGlobal: String, webView: WKWebView) {
        self.jsGlobal = jsGlobal
        self.webView = webView
    }

    func reply(id: Int, result: Any) {
        evaluate(call: "__handleResponse",
                 args: [String(id), Self.jsonLiteral(result), "null"])
    }

    /// `errorObject` is the wire-format error dict — `{code, message}`
    /// for the Ethereum bridge, optionally `{code, message, data: {...}}`
    /// for the Swarm bridge. Caller composes; channel only encodes.
    func reply(id: Int, errorObject: [String: Any]) {
        evaluate(call: "__handleResponse",
                 args: [String(id), "null", Self.jsonLiteral(errorObject)])
    }

    func emit(event: String, data: Any) {
        evaluate(call: "__handleEvent",
                 args: [Self.jsonLiteral(event), Self.jsonLiteral(data)])
    }

    private func evaluate(call: String, args: [String]) {
        guard let webView else { return }
        let argList = args.joined(separator: ", ")
        let js = "window.\(jsGlobal) && window.\(jsGlobal).\(call)(\(argList));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// JSONSerialization quotes + escapes strings, so direct
    /// interpolation into evaluateJavaScript is injection-safe. Returns
    /// `"null"` on failure — the JS handler treats that as a missing
    /// result/error and does nothing.
    private static func jsonLiteral(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.fragmentsAllowed]
        ),
              let string = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return string
    }
}
