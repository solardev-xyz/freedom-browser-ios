import Foundation
import IPFSKit
import WebKit

/// Mutable per-tab state describing the current top-level
/// `ipfs://` / `ipns://` navigation, if any. Owned by `BrowserTab`,
/// shared with that tab's two scheme handlers (one for each scheme).
/// The handlers stamp correlation headers on outgoing requests so
/// the Rust gateway can group subresource progress events under
/// their parent navigation in `progressSnapshot`.
///
/// `topLevelPath` is the gateway-style path
/// (`/ipfs/<cid>/...` or `/ipns/<name>/...`) of the page WebKit is
/// loading right now. `rootRequestID` is filled in by the scheme
/// handler when it sees the request whose path matches
/// `topLevelPath` — that id then becomes
/// `X-Freedom-Parent-Request-ID` for every subresource.
@MainActor
final class IpfsNavContext {
    private(set) var topLevelPath: String?
    private(set) var rootRequestID: UInt64?

    func begin(topLevelPath: String) {
        self.topLevelPath = topLevelPath
        rootRequestID = nil
    }

    func end() {
        topLevelPath = nil
        rootRequestID = nil
    }

    /// Called by the scheme handler when it sees the request whose
    /// path matches `topLevelPath`. Subsequent subresource requests
    /// for the same navigation stamp this id as
    /// `X-Freedom-Parent-Request-ID`.
    func recordRootRequestID(_ id: UInt64) {
        rootRequestID = id
    }
}

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
/// 4. Stamps `X-Freedom-Request-ID` / `X-Freedom-Parent-Request-ID` /
///    `X-Freedom-Top-Level-Path` correlation headers so the Rust
///    gateway can group subresource progress events under their
///    parent navigation.
@MainActor
final class IpfsSchemeHandler: NSObject, WKURLSchemeHandler {
    /// Permissive CORS so cross-content `fetch('ipfs://<cid>/')` from an
    /// `ipfs://` page works, matching desktop's `corsEnabled: true`
    /// scheme registration.
    static let corsResponseHeaders: [String: String] = [
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Range",
        "Access-Control-Max-Age": "600",
        "Access-Control-Expose-Headers": "Content-Length, Content-Range",
    ]

    /// Weak ref — the node is owned by `FreedomApp` and outlives any
    /// individual tab. A weak ref keeps tabs from extending the node's
    /// lifetime past app teardown.
    private weak var node: IPFSNode?
    /// Weak ref — the navigation context lives on `BrowserTab`. When
    /// the tab is gone the handler still works, just without
    /// correlation grouping.
    private weak var navContext: IpfsNavContext?

    private var session: URLSession!
    private let delegateBox = SessionDelegate()
    private var active: [Int: PendingRequest] = [:]

    init(node: IPFSNode, navContext: IpfsNavContext? = nil) {
        self.node = node
        self.navContext = navContext
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
              let urlGatewayPath = Self.gatewayStylePath(for: originalURL),
              let httpURL = Self.localHTTPURL(
                originalURL: originalURL,
                gatewayPath: urlGatewayPath,
                gateway: node?.gatewayURL
              )
        else {
            task.didFailWithError(URLError(.badURL))
            return
        }

        // Short-circuit OPTIONS preflights at the handler. The Rust
        // reader serves verified GET/HEAD only; a passthrough OPTIONS
        // would error out and the actual request would never run.
        if (task.request.httpMethod ?? "GET").uppercased() == "OPTIONS" {
            let response = HTTPURLResponse(
                url: originalURL,
                statusCode: 204,
                httpVersion: "HTTP/1.1",
                headerFields: Self.corsResponseHeaders
            )!
            task.didReceive(response)
            task.didReceive(Data()) // WKURLSchemeTask contract: body call required before didFinish
            task.didFinish()
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

        stampCorrelationHeaders(on: &request, urlGatewayPath: urlGatewayPath)

        let dataTask = session.dataTask(with: request)
        active[dataTask.taskIdentifier] = PendingRequest(
            schemeTask: task,
            originalURL: originalURL
        )
        dataTask.resume()
    }

    /// Stamps `X-Freedom-Request-ID` on every outgoing request and,
    /// when a top-level navigation context is available, also stamps
    /// `X-Freedom-Top-Level-Path` and (for subresources)
    /// `X-Freedom-Parent-Request-ID`. The Rust gateway uses these to
    /// group subresource progress events under their parent
    /// navigation in the snapshot.
    private func stampCorrelationHeaders(on request: inout URLRequest, urlGatewayPath: String) {
        guard let requestID = node?.nextGatewayRequestID() else { return }
        request.setValue("\(requestID)", forHTTPHeaderField: "X-Freedom-Request-ID")
        guard let context = navContext,
              let topLevelPath = context.topLevelPath
        else { return }
        request.setValue(topLevelPath, forHTTPHeaderField: "X-Freedom-Top-Level-Path")
        if urlGatewayPath == topLevelPath {
            // Page's root request — record so subresource requests
            // can stamp it as their parent.
            context.recordRootRequestID(requestID)
        } else if let parent = context.rootRequestID {
            request.setValue("\(parent)", forHTTPHeaderField: "X-Freedom-Parent-Request-ID")
        } else {
            // Subresource arrived before the root request landed.
            // Gateway tracks it as standalone; later subresources
            // get correlated once the root lands.
        }
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

    /// Compute the gateway-style path for an `ipfs://` / `ipns://`
    /// URL. Returns `/ipfs/<cid>/<path>` or `/ipns/<name>/<path>`,
    /// with the nested-fetch passthrough: when a JS app on an
    /// `ipfs://` origin issues a relative `/ipfs/<other-cid>/...`,
    /// that arrives here as `ipfs://<this-cid>/ipfs/<other-cid>/...`
    /// — we pass the inner path through unchanged so the gateway
    /// serves the referenced content rather than nesting CIDs.
    /// Returns `nil` for non-ipfs URLs.
    static func gatewayStylePath(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "ipfs" || scheme == "ipns",
              let host = url.host else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        if path.hasPrefix("/ipfs/") || path.hasPrefix("/ipns/") {
            return path
        }
        return "/\(scheme)/\(host)\(path)"
    }

    /// Translate `ipfs://<cid>/<path>` → `http://<gateway>/ipfs/<cid>/<path>`,
    /// and `ipns://<name>/<path>` → `http://<gateway>/ipns/<name>/<path>`.
    /// Callers compute `gatewayPath` once via `gatewayStylePath(for:)`
    /// so we don't recompute it for both this and the correlation-
    /// header stamping.
    static func localHTTPURL(originalURL: URL, gatewayPath: String, gateway: URL?) -> URL? {
        guard let gateway,
              let gatewayHost = gateway.host,
              let gatewayPort = gateway.port,
              let gatewayScheme = gateway.scheme
        else { return nil }

        var components = URLComponents()
        components.scheme = gatewayScheme
        components.host = gatewayHost
        components.port = gatewayPort
        components.path = gatewayPath
        components.percentEncodedQuery =
            URLComponents(url: originalURL, resolvingAgainstBaseURL: false)?.percentEncodedQuery
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
        // the requesting page, and overlay permissive CORS headers so
        // cross-content `ipfs://<other-cid>/` fetches from other
        // `ipfs://` pages succeed.
        var headers = http.allHeaderFields as? [String: String] ?? [:]
        headers.merge(Self.corsResponseHeaders) { _, new in new }
        let rewritten = HTTPURLResponse(
            url: pending.originalURL,
            statusCode: http.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
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
