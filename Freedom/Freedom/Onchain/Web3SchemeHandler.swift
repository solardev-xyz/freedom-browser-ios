import Foundation
import WebKit

/// Serves `web3://<contract>.eip155-<chainId>/…` documents that the
/// owning tab has already fetched, gated and staged. Nothing else: no
/// fetch of its own, no subresources, no other origins. That is what
/// makes the gate airtight without desktop's token machinery — the only
/// way bytes reach WebKit under a `web3:` origin is through
/// `BrowserTab`, which fetched them once, showed the interstitial when
/// needed and staged exactly those bytes. A hostile page fetching or
/// framing `web3://…` gets a refusal.
@MainActor
final class Web3SchemeHandler: NSObject, WKURLSchemeHandler {
    /// Desktop `ONCHAIN_APP_CSP` verbatim: inline code and embedded
    /// media work, ambient network, frames, workers, plugins, base URL
    /// changes and form posts don't. `sandbox` keeps the contract+chain
    /// origin for app-local storage while denying popups and scripted
    /// top-level navigation.
    static let contentSecurityPolicy = [
        "default-src 'none'",
        "script-src 'unsafe-inline' blob:",
        "style-src 'unsafe-inline'",
        "img-src data: blob:",
        "font-src data:",
        "media-src data: blob:",
        "connect-src 'none'",
        "object-src 'none'",
        "frame-src 'none'",
        "worker-src 'none'",
        "base-uri 'none'",
        "form-action 'none'",
        "frame-ancestors 'none'",
        "sandbox allow-scripts allow-same-origin allow-forms allow-modals allow-downloads",
    ].joined(separator: "; ")

    static let permissionsPolicy = [
        "accelerometer=()", "camera=()", "display-capture=()", "geolocation=()",
        "gyroscope=()", "microphone=()", "midi=()", "payment=()",
        "publickey-credentials-create=()", "publickey-credentials-get=()", "usb=()",
    ].joined(separator: ", ")

    /// Documents kept per tab, most recent last. Back/forward within the
    /// last few apps serves from here; anything older re-fetches through
    /// the tab (and re-gates if unverified).
    static let capacity = 8

    private var staged: [OnchainAppRef: OnchainAppDocument] = [:]
    private var order: [OnchainAppRef] = []

    func stage(_ document: OnchainAppDocument) {
        let app = document.app
        order.removeAll { $0 == app }
        order.append(app)
        staged[app] = document
        while order.count > Self.capacity {
            staged.removeValue(forKey: order.removeFirst())
        }
    }

    func stagedDocument(for app: OnchainAppRef) -> OnchainAppDocument? {
        staged[app]
    }

    func hasStagedDocument(for url: URL) -> Bool {
        guard let (app, _) = OnchainAppRef.parse(url) else { return false }
        return staged[app] != nil
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let method = (task.request.httpMethod ?? "GET").uppercased()
        guard method == "GET" || method == "HEAD" else {
            respond(task, url: url, status: 405, text: "onchain applications only support GET and HEAD",
                    extra: ["Allow": "GET, HEAD"])
            return
        }
        guard Self.isCanonical(url), let (app, _) = OnchainAppRef.parse(url) else {
            respond(task, url: url, status: 400,
                    text: "invalid onchain application URL; expected web3://<contract>.eip155-<chainId>/")
            return
        }
        // Top-level document loads only. A subresource or frame request
        // carries the embedding page as its main document.
        guard Self.isTopLevel(task.request) else {
            respond(task, url: url, status: 403, text: "onchain applications load as top-level documents only")
            return
        }
        guard let document = staged[app] else {
            // Not fetched by this tab (evicted, or a navigation that
            // bypassed the tab). The link routes back through the tab,
            // which fetches, gates and stages.
            respond(task, url: url, status: 404, html: Self.reloadPage(for: app))
            return
        }
        let data = Data(document.html.utf8)
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: Self.documentHeaders(for: document.provenance, byteCount: data.count)
        )!
        task.didReceive(response)
        task.didReceive(method == "HEAD" ? Data() : data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // Every response is delivered synchronously in `start`; nothing
        // to cancel.
    }

    // MARK: - Helpers

    static func isCanonical(_ url: URL) -> Bool {
        url.host?.lowercased().contains(".eip155-") == true
    }

    /// WebKit sets `mainDocumentURL` to the request itself for a
    /// top-level load; for subresources and frames it is the embedding
    /// document. Missing main document fails closed.
    static func isTopLevel(_ request: URLRequest) -> Bool {
        guard let url = request.url, let main = request.mainDocumentURL else { return false }
        return stripFragment(main) == stripFragment(url)
    }

    private static func stripFragment(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }

    static func documentHeaders(for provenance: OnchainAppProvenance, byteCount: Int) -> [String: String] {
        [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Length": String(byteCount),
            "Cache-Control": "no-store",
            "Content-Security-Policy": contentSecurityPolicy,
            "Permissions-Policy": permissionsPolicy,
            "Referrer-Policy": "no-referrer",
            "X-Content-Type-Options": "nosniff",
            "X-Frame-Options": "DENY",
            "X-Freedom-Onchain-App-Chain-Id": String(provenance.app.chainID),
            "X-Freedom-Onchain-App-Contract": provenance.app.address,
            "X-Freedom-Onchain-App-Source": provenance.source,
            "X-Freedom-Onchain-App-Verified": provenance.trust.level == .verified ? "true" : "false",
            "X-Freedom-Onchain-App-Hash": provenance.htmlHash,
        ]
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, text: String, extra: [String: String] = [:]) {
        var headers = [
            "Content-Type": "text/plain; charset=utf-8",
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        ]
        headers.merge(extra) { _, new in new }
        let data = Data(text.utf8)
        headers["Content-Length"] = String(data.count)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, html: String) {
        let data = Data(html.utf8)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Length": String(data.count),
                "Cache-Control": "no-store",
                "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'",
                "X-Content-Type-Options": "nosniff",
            ]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    /// Shown when WebKit asks for an app this tab hasn't staged (e.g. a
    /// history entry after eviction). The link is a genuine user
    /// navigation, which `BrowserTab` intercepts and routes through the
    /// fetch-and-gate path.
    static func reloadPage(for app: OnchainAppRef) -> String {
        let href = app.displayURL().absoluteString
        return """
        <!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Onchain app not loaded</title>
        <style>body{font-family:-apple-system,system-ui;padding:24px;color:#111}code{word-break:break-all}</style>
        <h1>Onchain app not loaded</h1>
        <p>This tab hasn't fetched <code>\(href)</code> from the chain yet.</p>
        <p><a href="\(href)">Load it now</a></p>
        """
    }
}
