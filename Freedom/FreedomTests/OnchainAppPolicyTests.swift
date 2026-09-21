import XCTest
import WebKit
@testable import Freedom

/// Real WebKit: the CSP the handler attaches to a custom-scheme
/// response is enforced — inline script runs, ambient network is
/// denied — and a canonical `web3:` host is a real origin. This is the
/// property the whole isolation model rests on, so it's checked against
/// the engine rather than assumed.
@MainActor
final class OnchainAppPolicyTests: XCTestCase {
    nonisolated(unsafe) private static var leaked: [AnyObject] = []

    func testInlineScriptRunsAndFetchIsDeniedByCSP() async throws {
        let app = OnchainAppRef(address: "0x00000095643CFfA7D9fae407a84dfCB6406456c6", chainID: 1)!
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>start</title></head><body>
        <script>
          document.title = 'inline-ran';
          fetch('web3://\(app.lowercasedAddress).eip155-1/other')
            .then(() => { document.title = 'fetch-allowed'; })
            .catch(() => { document.title = 'fetch-blocked'; });
        </script>
        </body></html>
        """
        let document = OnchainAppDocument(
            html: html,
            provenance: OnchainAppProvenance(
                app: app, networkName: "Ethereum", htmlHash: OnchainAppRef.htmlHash(html),
                trust: TestTrust.verified()
            )
        )
        let handler = Web3SchemeHandler()
        handler.stage(document)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(handler, forURLScheme: OnchainAppRef.scheme)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            .with(configuration: config)
        Self.leaked.append(contentsOf: [handler, webView])

        webView.load(URLRequest(url: app.canonicalURL()))
        let deadline = Date(timeIntervalSinceNow: 15)
        var title = ""
        while Date() < deadline {
            title = (try? await webView.evaluateJavaScript("document.title") as? String) ?? ""
            if title == "fetch-blocked" || title == "fetch-allowed" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(title, "fetch-blocked", "connect-src 'none' must deny fetch; inline script must have run")

        let origin = try await webView.evaluateJavaScript("location.origin") as? String
        XCTAssertEqual(origin, "web3://\(app.lowercasedAddress).eip155-1")
        let storageOK = try await webView.evaluateJavaScript(
            "(function(){ try { localStorage.setItem('k','v'); return localStorage.getItem('k'); } catch (e) { return 'err:' + e.name } })()"
        ) as? String
        XCTAssertEqual(storageOK, "v", "sandbox allow-same-origin keeps app-local storage")
    }
}

private extension WKWebView {
    func with(configuration: WKWebViewConfiguration) -> WKWebView {
        WKWebView(frame: frame, configuration: configuration)
    }
}
