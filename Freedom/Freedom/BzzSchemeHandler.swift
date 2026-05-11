import Foundation
import WebKit

final class BzzSchemeHandler: NSObject, WKURLSchemeHandler {
    static let beeAPIPort: Int = 1633

    /// Permissive CORS so cross-content `fetch('bzz://<hex>/')` from a
    /// `bzz://` page works, matching desktop's `corsEnabled: true`
    /// scheme registration. Expose-Headers names the Swarm-specific
    /// `swarm-feed-*` and `swarm-soc-signature` headers so JS can read
    /// them off `/feeds/<owner>/<topic>` responses.
    static let corsResponseHeaders: [String: String] = [
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Range",
        "Access-Control-Max-Age": "600",
        "Access-Control-Expose-Headers":
            "Content-Length, Content-Range, swarm-feed-index, swarm-feed-index-next, swarm-soc-signature",
    ]

    private let session = URLSession.shared
    private var active: [ObjectIdentifier: URLSessionDataTask] = [:]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let bzzURL = task.request.url, let httpURL = Self.localHTTPURL(for: bzzURL) else {
            task.didFailWithError(URLError(.badURL))
            return
        }

        // Short-circuit OPTIONS preflights at the handler. Bee doesn't
        // implement OPTIONS on `/bzz/...` so a passthrough would 405
        // and the actual request would never run.
        if (task.request.httpMethod ?? "GET").uppercased() == "OPTIONS" {
            let response = HTTPURLResponse(
                url: bzzURL,
                statusCode: 204,
                httpVersion: "HTTP/1.1",
                headerFields: Self.corsResponseHeaders
            )!
            task.didReceive(response)
            task.didReceive(Data()) // WKURLSchemeTask contract: body call required before didFinish
            task.didFinish()
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
                // treats the response as same-origin with the requesting page,
                // and overlay permissive CORS headers so cross-origin
                // `bzz://<hex>/` fetches from other `bzz://` pages succeed.
                var headers = http.allHeaderFields as? [String: String] ?? [:]
                headers.merge(Self.corsResponseHeaders) { _, new in new }
                let rewritten = HTTPURLResponse(
                    url: bzzURL,
                    statusCode: http.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
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

    /// Translate a `bzz://` URL to its Bee HTTP API equivalent on localhost.
    /// When the path looks like a reserved Bee API route
    /// (/bzz/<ref>, /bytes/<ref>, /chunks/<ref>, /feeds/<owner>/<topic>,
    /// /soc/<owner>/<topic>), route directly — this is how Swarm SPAs issue
    /// relative `fetch('/bzz/<ref>/')` calls. Otherwise treat the path as
    /// a subpath inside the current origin's manifest.
    static func localHTTPURL(for bzzURL: URL) -> URL? {
        guard bzzURL.scheme == "bzz", let host = bzzURL.host else { return nil }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = beeAPIPort

        let path = bzzURL.path.isEmpty ? "/" : bzzURL.path
        if isBeeGatewayPath(path) {
            components.path = path
        } else {
            components.path = "/bzz/\(host)\(path)"
        }
        components.query = bzzURL.query
        return components.url
    }

    private static func isBeeGatewayPath(_ path: String) -> Bool {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count >= 2 else { return false }
        switch segments[0] {
        case "bzz", "bytes":
            return SwarmRef.isValid(segments[1])
        case "chunks":
            return SwarmRef.isHex(segments[1], length: 64)
        case "feeds", "soc":
            guard segments.count >= 3 else { return false }
            return SwarmRef.isHex(segments[1], length: 40) && SwarmRef.isHex(segments[2], length: 64)
        default:
            return false
        }
    }
}
