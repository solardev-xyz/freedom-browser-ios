import Foundation
import WebKit

/// Custom scheme handler for `ipfs://` and `ipns://`. Mirrors
/// `BzzSchemeHandler`'s shape: every request the WKWebView makes
/// against either scheme is translated to the kubo HTTP gateway on
/// localhost and proxied back through the URLSchemeTask.
final class IpfsSchemeHandler: NSObject, WKURLSchemeHandler {
    static let ipfsGatewayPort: Int = 5050

    private let session = URLSession.shared
    private var active: [ObjectIdentifier: URLSessionDataTask] = [:]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let originalURL = task.request.url, let httpURL = Self.localHTTPURL(for: originalURL) else {
            task.didFailWithError(URLError(.badURL))
            return
        }

        let key = ObjectIdentifier(task)
        let dataTask = session.dataTask(with: httpURL) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.active.removeValue(forKey: key) != nil else { return }
                if let error {
                    task.didFailWithError(error)
                    return
                }
                guard let http = response as? HTTPURLResponse, let data else {
                    task.didFailWithError(URLError(.badServerResponse))
                    return
                }
                // Rewrite the response URL back to the original ipfs/ipns
                // scheme so WebKit treats the response as same-origin
                // with the requesting page.
                let rewritten = HTTPURLResponse(
                    url: originalURL,
                    statusCode: http.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: http.allHeaderFields as? [String: String]
                ) ?? http
                task.didReceive(rewritten)
                task.didReceive(data)
                task.didFinish()
            }
        }
        active[key] = dataTask
        dataTask.resume()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        active.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }

    /// Translate `ipfs://<cid>/<path>` → `http://127.0.0.1:5050/ipfs/<cid>/<path>`,
    /// and `ipns://<name>/<path>` → `http://127.0.0.1:5050/ipns/<name>/<path>`.
    /// When a JS app on an `ipfs://` origin issues a relative
    /// `fetch('/ipfs/<other-cid>/…')` or `/ipns/<name>/…`, that arrives as
    /// `ipfs://<this-cid>/ipfs/<other-cid>/…` — pass the path through
    /// directly so kubo serves the referenced content rather than
    /// nesting it.
    static func localHTTPURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "ipfs" || scheme == "ipns",
              let host = url.host else { return nil }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = ipfsGatewayPort

        let path = url.path.isEmpty ? "/" : url.path
        if path.hasPrefix("/ipfs/") || path.hasPrefix("/ipns/") {
            components.path = path
        } else {
            components.path = "/\(scheme)/\(host)\(path)"
        }
        components.query = url.query
        return components.url
    }
}
