import Foundation
import WebKit

final class BzzSchemeHandler: NSObject, WKURLSchemeHandler {
    private let beeAPIPort: Int = 1633
    private let session = URLSession.shared
    private var active: [ObjectIdentifier: URLSessionDataTask] = [:]

    // Bee HTTP API read-path shapes. When the path matches one of these
    // exactly (including the expected hex-reference format), we route the
    // request straight to Bee, bypassing the current page's origin hash.
    // Otherwise the request is interpreted as a path inside the origin's
    // manifest. Shapes here mirror the Bee HTTP API's own router so we
    // reserve exactly the same namespace any Swarm gateway already reserves.
    private func isBeeGatewayPath(_ path: String) -> Bool {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count >= 2 else { return false }
        switch segments[0] {
        case "bzz", "bytes":
            // /bzz/<64 or 128 hex>[/...]
            return isSwarmRef(segments[1])
        case "chunks":
            // /chunks/<64 hex>
            return isHex(segments[1], length: 64)
        case "feeds", "soc":
            // /feeds/<owner: 40 hex>/<topic: 64 hex>
            guard segments.count >= 3 else { return false }
            return isHex(segments[1], length: 40) && isHex(segments[2], length: 64)
        default:
            return false
        }
    }

    private func isSwarmRef(_ s: Substring) -> Bool {
        (s.count == 64 || s.count == 128) && s.allSatisfy(\.isHexDigit)
    }

    private func isHex(_ s: Substring, length: Int) -> Bool {
        s.count == length && s.allSatisfy(\.isHexDigit)
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let bzzURL = task.request.url, let httpURL = translate(bzzURL) else {
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
                // Rewrite the response URL back to the bzz:// scheme so WebKit
                // treats the response as same-origin with the requesting page.
                let rewritten = HTTPURLResponse(
                    url: bzzURL,
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

    private func translate(_ url: URL) -> URL? {
        guard url.scheme == "bzz", let host = url.host else { return nil }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = beeAPIPort

        let path = url.path.isEmpty ? "/" : url.path

        if isBeeGatewayPath(path) {
            // SPA is addressing a *different* Swarm reference via relative
            // /bzz/<ref>/ path. Route to Bee directly, ignoring origin.
            components.path = path
        } else {
            // Regular in-manifest navigation — prefix with origin hash so Bee
            // walks the current site's manifest.
            components.path = "/bzz/\(host)\(path)"
        }
        components.query = url.query
        return components.url
    }
}
