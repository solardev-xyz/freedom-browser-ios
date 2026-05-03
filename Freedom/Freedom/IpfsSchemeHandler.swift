import Foundation
import IPFSKit
import WebKit

/// Custom scheme handler for `ipfs://` and `ipns://`. Translates each
/// request the WKWebView issues against either scheme into an HTTP
/// request against the running Rust IPFS gateway on a loopback address,
/// and streams the response back through the WKURLSchemeTask.
///
/// Three things distinguish this from the previous Kubo-era handler:
/// 1. The gateway port is read live from `IPFSNode.gatewayURL` — no
///    hardcoded `127.0.0.1:5050` anymore. The Rust reader binds
///    ephemeral ports.
/// 2. Forwards selected request headers (notably `Range`) through to
///    the gateway so WebKit's media loaders can issue byte-range
///    requests.
/// 3. Streams response bytes incrementally via URLSession delegate
///    callbacks so large responses don't get buffered whole into RAM.
@MainActor
final class IpfsSchemeHandler: NSObject, WKURLSchemeHandler {
    /// Weak ref — the node is owned by `FreedomApp` and outlives any
    /// individual tab. A weak ref keeps tabs from extending the node's
    /// lifetime past app teardown.
    private weak var node: IPFSNode?

    private var session: URLSession!
    private let delegateBox = SessionDelegate()
    private var active: [Int: PendingRequest] = [:]

    init(node: IPFSNode) {
        self.node = node
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        // Loopback localhost — no proxies, no cookies, no shared cache.
        config.connectionProxyDictionary = [:]
        config.httpShouldUsePipelining = true
        // Delegate callbacks must reach the main actor before they touch
        // WKURLSchemeTask methods; running the delegate queue on
        // `.main` removes the need for an extra hop.
        self.session = URLSession(
            configuration: config,
            delegate: delegateBox,
            delegateQueue: OperationQueue.main
        )
        delegateBox.handler = self
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let originalURL = task.request.url,
              let httpURL = Self.localHTTPURL(for: originalURL, gateway: node?.gatewayURL)
        else {
            task.didFailWithError(URLError(.badURL))
            return
        }

        var request = URLRequest(url: httpURL)
        request.httpMethod = task.request.httpMethod ?? "GET"
        request.httpBody = task.request.httpBody
        // Forward all WebKit-supplied headers — Range, If-None-Match,
        // If-Modified-Since, Accept, Accept-Encoding, Cache-Control,
        // etc. The localhost gateway can ignore anything it doesn't
        // care about; dropping headers selectively risks breaking
        // `<video>`/`<audio>` byte-range loads which the player
        // negotiates via `Range`.
        for (key, value) in (task.request.allHTTPHeaderFields ?? [:]) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // Strip Host — URLSession sets it from the URL.
        request.setValue(nil, forHTTPHeaderField: "Host")

        let dataTask = session.dataTask(with: request)
        active[dataTask.taskIdentifier] = PendingRequest(
            schemeTask: task,
            originalURL: originalURL
        )
        dataTask.resume()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // Find and cancel any in-flight URLSession data task pinned to
        // this scheme task. The session-level callback will see the
        // cancellation and clean up `active` on its own.
        for (id, req) in active where req.schemeTask === task {
            req.cancelled = true
            session.getTasksWithCompletionHandler { _, _, dataTasks in
                for t in dataTasks where t.taskIdentifier == id {
                    t.cancel()
                }
            }
        }
    }

    /// Translate `ipfs://<cid>/<path>` → `http://<gateway>/ipfs/<cid>/<path>`,
    /// and `ipns://<name>/<path>` → `http://<gateway>/ipns/<name>/<path>`.
    /// Special case for nested fetches: when a JS app on an `ipfs://`
    /// origin issues a relative `/ipfs/<other-cid>/…`, that arrives as
    /// `ipfs://<this-cid>/ipfs/<other-cid>/…`. Pass that path through
    /// directly so the gateway serves the referenced content rather
    /// than nesting CIDs.
    static func localHTTPURL(for url: URL, gateway: URL?) -> URL? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "ipfs" || scheme == "ipns",
              let host = url.host else { return nil }
        guard let gateway,
              let gatewayHost = gateway.host,
              let gatewayPort = gateway.port,
              let gatewayScheme = gateway.scheme
        else { return nil }

        let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)

        var components = URLComponents()
        components.scheme = gatewayScheme
        components.host = gatewayHost
        components.port = gatewayPort

        let path = url.path.isEmpty ? "/" : url.path
        if path.hasPrefix("/ipfs/") || path.hasPrefix("/ipns/") {
            components.path = path
        } else {
            components.path = "/\(scheme)/\(host)\(path)"
        }
        components.percentEncodedQuery = urlComponents?.percentEncodedQuery
        return components.url
    }

    // MARK: - Per-task state

    final class PendingRequest {
        let schemeTask: WKURLSchemeTask
        let originalURL: URL
        var didReceiveResponse = false
        var cancelled = false

        init(schemeTask: WKURLSchemeTask, originalURL: URL) {
            self.schemeTask = schemeTask
            self.originalURL = originalURL
        }
    }

    fileprivate func handleResponse(
        for taskID: Int,
        response: URLResponse,
        completion: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let pending = active[taskID], !pending.cancelled else {
            completion(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            pending.schemeTask.didFailWithError(URLError(.badServerResponse))
            active[taskID] = nil
            completion(.cancel)
            return
        }
        // Rewrite the response URL back to the original `ipfs://` /
        // `ipns://` so WebKit treats the response as same-origin with
        // the requesting page.
        let rewritten = HTTPURLResponse(
            url: pending.originalURL,
            statusCode: http.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: http.allHeaderFields as? [String: String]
        ) ?? http
        do {
            pending.schemeTask.didReceive(rewritten)
            pending.didReceiveResponse = true
            completion(.allow)
        }
    }

    fileprivate func handleData(for taskID: Int, data: Data) {
        guard let pending = active[taskID], !pending.cancelled, pending.didReceiveResponse else {
            return
        }
        pending.schemeTask.didReceive(data)
    }

    fileprivate func handleCompletion(for taskID: Int, error: Error?) {
        guard let pending = active.removeValue(forKey: taskID) else { return }
        if pending.cancelled { return }
        if let error {
            pending.schemeTask.didFailWithError(error)
            return
        }
        if !pending.didReceiveResponse {
            pending.schemeTask.didFailWithError(URLError(.badServerResponse))
            return
        }
        pending.schemeTask.didFinish()
    }
}

/// URLSession delegate. Bridges streaming callbacks back to the
/// scheme handler, which forwards them to the WKURLSchemeTask. Lives
/// on `OperationQueue.main` so every callback is already main-actor
/// when the bridge runs.
private final class SessionDelegate: NSObject, URLSessionDataDelegate {
    weak var handler: IpfsSchemeHandler?

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let id = dataTask.taskIdentifier
        MainActor.assumeIsolated {
            handler?.handleResponse(for: id, response: response, completion: completionHandler)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let id = dataTask.taskIdentifier
        MainActor.assumeIsolated {
            handler?.handleData(for: id, data: data)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let id = task.taskIdentifier
        MainActor.assumeIsolated {
            handler?.handleCompletion(for: id, error: error)
        }
    }
}
