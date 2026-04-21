import Foundation
import WebKit

final class BzzSchemeHandler: NSObject, WKURLSchemeHandler {
    static let beeAPIPort: Int = 1633

    private let session = URLSession.shared
    private var active: [ObjectIdentifier: URLSessionDataTask] = [:]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let bzzURL = task.request.url, let httpURL = Self.localHTTPURL(for: bzzURL) else {
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
