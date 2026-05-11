import Foundation
import WebKit

@MainActor
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
    private let ensResolver: any ENSResolving
    private var active: [ObjectIdentifier: URLSessionDataTask] = [:]
    /// Tracks scheme tasks whose ENS resolution is in flight. The
    /// existing `active` dict is keyed by `dataTask.taskIdentifier`,
    /// which doesn't exist yet at this stage — so `stop(_:)` needs a
    /// separate place to mark the scheme task cancelled.
    private var pendingResolutions: [ObjectIdentifier: PendingResolution] = [:]

    init(ensResolver: any ENSResolving) {
        self.ensResolver = ensResolver
        super.init()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let bzzURL = task.request.url else {
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

        // ENS-named host (`bzz://swarm.eth/...`): resolve via ENS,
        // verify codec, then form the upstream URL against the
        // resolved swarm reference. Non-`.eth` hosts continue
        // straight to the existing CID/hash path.
        if bzzURL.isENSNamedHost, let host = bzzURL.host?.lowercased() {
            startWithENSResolution(originalURL: bzzURL, name: host, task: task)
            return
        }

        guard let httpURL = Self.localHTTPURL(for: bzzURL) else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        startUpstreamFetch(upstreamURL: httpURL, responseURL: bzzURL, task: task)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        if let pending = pendingResolutions.removeValue(forKey: key) {
            pending.cancelled = true
            return
        }
        active.removeValue(forKey: key)?.cancel()
    }

    // MARK: - ENS resolution

    private func startWithENSResolution(originalURL: URL, name: String, task: WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        let pending = PendingResolution()
        pendingResolutions[key] = pending
        Task { [weak self] in
            guard let self else { return }
            defer { self.pendingResolutions.removeValue(forKey: key) }
            do {
                let resolved = try await self.ensResolver.resolveContent(name)
                guard !pending.cancelled else { return }
                self.handleENSResolved(originalURL: originalURL, resolved: resolved, task: task)
            } catch {
                guard !pending.cancelled else { return }
                self.respondWithError(
                    originalURL: originalURL,
                    statusCode: 502,
                    body: SchemeHandlerErrorPage.render(.resolutionFailed(
                        name: name,
                        message: ENSErrorFormatting.describe(error)
                    )),
                    task: task
                )
            }
        }
    }

    private func handleENSResolved(originalURL: URL, resolved: ENSResolvedContent, task: WKURLSchemeTask) {
        guard resolved.codec == .bzz else {
            respondWithError(
                originalURL: originalURL,
                statusCode: 404,
                body: SchemeHandlerErrorPage.render(.codecMismatch(
                    requestedScheme: "bzz",
                    resolvedScheme: resolved.codec.scheme,
                    name: resolved.name
                )),
                task: task
            )
            return
        }
        guard let upstreamURL = Self.localHTTPURL(for: originalURL, resolvedTo: resolved.contentRef) else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        startUpstreamFetch(upstreamURL: upstreamURL, responseURL: originalURL, task: task)
    }

    // MARK: - Response paths

    private func startUpstreamFetch(upstreamURL: URL, responseURL: URL, task: WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        let dataTask = session.dataTask(with: upstreamURL) { [weak self] data, response, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
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
                        url: responseURL,
                        statusCode: http.statusCode,
                        httpVersion: "HTTP/1.1",
                        headerFields: headers
                    ) ?? http
                    task.didReceive(rewritten)
                    task.didReceive(data)
                    task.didFinish()
                }
            }
        }
        active[key] = dataTask
        dataTask.resume()
    }

    private func respondWithError(
        originalURL: URL,
        statusCode: Int,
        body: String,
        task: WKURLSchemeTask
    ) {
        let data = Data(body.utf8)
        var headers: [String: String] = [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Length": "\(data.count)",
        ]
        headers.merge(Self.corsResponseHeaders) { _, new in new }
        let response = HTTPURLResponse(
            url: originalURL,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    // MARK: - URL translation

    /// Translate a `bzz://` URL to its Bee HTTP API equivalent on localhost.
    /// When the path looks like a reserved Bee API route
    /// (/bzz/<ref>, /bytes/<ref>, /chunks/<ref>, /feeds/<owner>/<topic>,
    /// /soc/<owner>/<topic>), route directly — this is how Swarm SPAs issue
    /// relative `fetch('/bzz/<ref>/')` calls. Otherwise treat the path as
    /// a subpath inside the current origin's manifest.
    ///
    /// When `resolvedTo` is non-nil, the URL's host (an ENS name) is
    /// replaced by the resolved swarm reference for the non-gateway-path
    /// branch — so `bzz://swarm.eth/index.html` with `resolvedTo: <hex>`
    /// becomes `/bzz/<hex>/index.html`. The gateway-path branch is
    /// unaffected: `bzz://swarm.eth/bzz/<other-hex>/` still routes to
    /// the explicitly-named ref, matching today's relative-fetch behavior.
    static func localHTTPURL(for bzzURL: URL, resolvedTo contentRef: String? = nil) -> URL? {
        guard bzzURL.scheme == "bzz", let host = bzzURL.host else { return nil }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = beeAPIPort

        // `URL.path` strips trailing slashes (Foundation quirk); the
        // percent-encoded accessor preserves them, so directory-shaped
        // requests like `bzz://<ref>/foo/` actually reach Bee as
        // `/bzz/<ref>/foo/` rather than the slash-stripped form.
        let raw = bzzURL.path(percentEncoded: false)
        let path = raw.isEmpty ? "/" : raw
        if isBeeGatewayPath(path) {
            components.path = path
        } else {
            let effectiveHost = contentRef ?? host
            components.path = "/bzz/\(effectiveHost)\(path)"
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
