import Foundation
import RadicleKit
import WebKit

/// `rad:` scheme handler — the READ path of the Radicle integration.
/// Any page (the primary consumer is dweb frontends like canopy) can
/// `fetch('rad:<rid>/<path>')` public repo data straight out of the
/// embedded node's storage. Both URL forms work: `rad:<rid>/…` (the
/// canonical URN form canopy builds) and `rad://<rid>/…`.
///
/// This is the iOS port of desktop's native serving core
/// (`radicle-api-protocol.js` `serveRepoApi`, reached through
/// `radicle/rad-protocol.js`) — same endpoints, same JSON shapes, same
/// gates:
///  - GET / HEAD only (plus OPTIONS preflight, answered empty). Writes
///    go through the consented `window.radicle` provider, never here.
///  - Only the repo-scoped surface is reachable; node-level endpoints
///    (repo listing, node info) are private to the user.
///  - Public repos only — private repos 403 on this unconsented surface.
///  - CORS-open (`Access-Control-Allow-Origin: *`): repo data is public
///    P2P content and the sensitive surface is excluded above.
///  - Gated on the Radicle integration being enabled (403) and the node
///    running (503), checked per request.
///
/// Endpoints (all under `rad:<rid>`):
///   (root)              → repo metadata (httpd `payloads` shape)
///   /tree/SHA[/path]    → tree entries at the commit
///   /blob/SHA/path      → blob content at the commit
///   /readme/SHA         → root readme blob, 404 when absent
///   /commits?parent=SHA → paginated commit history
///   /commits/SHA        → commit metadata + structured diff
///   /stats/tree/SHA     → commit/branch/contributor counts
///   /remotes            → signed remote branch heads
///   /issues[/ID]        → issue reads (list paginated, `status` filter)
///   /patches[/ID]       → patch reads (same)
///
/// Revisions are full 40-hex commit ids only — refs and revspecs are
/// rejected at this boundary, exactly like desktop.
@MainActor
final class RadSchemeHandler: NSObject, WKURLSchemeHandler {
    private static let corsHeaders: [String: String] = [
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type",
        "Access-Control-Max-Age": "600",
    ]

    private let services: RadicleServices
    /// Live scheme tasks; `stop(_:)` removes, and every response checks
    /// membership first — WebKit hard-crashes on replies to a stopped task.
    private var liveTasks: Set<ObjectIdentifier> = []

    init(services: RadicleServices) {
        self.services = services
        super.init()
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let key = ObjectIdentifier(task)
        liveTasks.insert(key)
        let method = (task.request.httpMethod ?? "GET").uppercased()

        if method == "OPTIONS" {
            respond(task, key: key, status: 204, body: Data(), headOnly: false)
            return
        }
        guard method == "GET" || method == "HEAD" else {
            respondJSON(task, key: key, status: 405,
                        object: ["error": "method not allowed"], headOnly: false)
            return
        }

        let urlString = url.absoluteString
        Task { [weak self] in
            guard let self else { return }
            let (status, object) = await self.serve(urlString: urlString)
            self.respondJSON(task, key: key, status: status, object: object,
                             headOnly: method == "HEAD")
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        liveTasks.remove(ObjectIdentifier(task))
    }

    // MARK: - URL parsing (desktop rad-protocol parity)

    struct ParsedRadURL {
        /// Full RID with the `rad:` prefix, as the Rust layer parses it.
        let rid: String
        /// Decoded path segments under the repo root.
        let segments: [String]
        let query: [String: String]
    }

    /// Hand-parsed, never URL-canonicalized: the base58 RID is
    /// case-sensitive, so the URL arrives verbatim and is split here —
    /// same rationale as desktop's non-standard scheme registration.
    nonisolated static func parse(_ urlString: String) -> ParsedRadURL? {
        var remainder: Substring
        if urlString.hasPrefix("rad://") {
            remainder = urlString.dropFirst(6)
        } else if urlString.hasPrefix("rad:") {
            remainder = urlString.dropFirst(4)
        } else {
            return nil
        }

        var queryString = ""
        if let q = remainder.firstIndex(of: "?") {
            queryString = String(remainder[remainder.index(after: q)...])
            remainder = remainder[..<q]
        }

        let rid: Substring
        let path: Substring
        if let slash = remainder.firstIndex(of: "/") {
            rid = remainder[..<slash]
            path = remainder[slash...]
        } else {
            rid = remainder
            path = ""
        }

        guard String(rid).range(
            of: "^z[1-9A-HJ-NP-Za-km-z]{20,60}$", options: .regularExpression
        ) != nil else { return nil }

        // Segment-level validation mirrors decodeRepoApiPath: reject
        // backslashes, interior empty segments (`//`), `.`/`..`, control
        // chars, and encoded separators (decoding happens per segment,
        // so an encoded `/` can't create a new segment afterwards).
        var segments: [String] = []
        if !path.isEmpty {
            if path.contains("\\") { return nil }
            let raw = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            for (index, segment) in raw.enumerated() {
                if segment.isEmpty {
                    if index == raw.count - 1 { continue }
                    return nil
                }
                guard let decoded = String(segment).removingPercentEncoding else { return nil }
                if decoded == "." || decoded == ".." { return nil }
                if decoded.contains(where: { $0.asciiValue.map { $0 < 0x20 || $0 == 0x7f } ?? false })
                    || decoded.contains("/") || decoded.contains("\\") {
                    return nil
                }
                segments.append(decoded)
            }
        }

        var query: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let name = String(parts[0]).removingPercentEncoding else { continue }
            let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? "") : ""
            query[name] = value
        }

        return ParsedRadURL(rid: "rad:\(rid)", segments: segments, query: query)
    }

    private nonisolated static func isRevision(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
    }

    // MARK: - Serving

    private func serve(urlString: String) async -> (Int, Any) {
        if let reason = services.nodeFailureReason() {
            if reason == RadicleBridge.ErrorPayload.Reason.integrationDisabled {
                return (403, ["error": "Radicle integration is disabled"])
            }
            return (503, ["error": "Radicle node is not ready"])
        }
        guard let parsed = Self.parse(urlString) else {
            return (400, ["error": "invalid rad reference"])
        }

        // Public-repo gate: this surface is unconsented, so private
        // repos are invisible through it (desktop parity).
        let infoResult = await call(services.node.repoInfoJSON(rid: parsed.rid))
        guard case .ok(let info) = infoResult else {
            return infoResult.errorResponse
        }
        let visibility = (info as? [String: Any])?["visibility"] as? [String: Any]
        guard visibility?["type"] as? String == "public" else {
            return (403, ["error": "repository is not public"])
        }

        let section = parsed.segments.first
        let revision = parsed.segments.count > 1 ? parsed.segments[1] : nil
        let node = services.node
        let rid = parsed.rid

        switch section {
        case nil:
            return await buildRepoMeta(rid: rid, info: info)

        case "tree":
            guard Self.isRevision(revision) else {
                return (400, ["error": "missing revision"])
            }
            let path = parsed.segments.dropFirst(2).joined(separator: "/")
            return unwrap(await call(node.treeAtJSON(rid: rid, revision: revision!, path: path)))

        case "blob":
            let path = parsed.segments.dropFirst(2).joined(separator: "/")
            guard Self.isRevision(revision), !path.isEmpty else {
                return (400, ["error": "missing path"])
            }
            return unwrap(await call(node.blobAtJSON(rid: rid, revision: revision!, path: path)))

        case "readme":
            guard Self.isRevision(revision) else {
                return (400, ["error": "missing revision"])
            }
            return await readme(rid: rid, revision: revision!)

        case "commits":
            guard parsed.segments.count <= 2 else {
                return (400, ["error": "invalid commit path"])
            }
            if let revision {
                guard Self.isRevision(revision) else {
                    return (400, ["error": "invalid revision"])
                }
                return unwrap(await call(node.commitJSON(rid: rid, revision: revision)))
            }
            guard let parent = parsed.query["parent"], Self.isRevision(parent) else {
                return (400, ["error": "missing parent revision"])
            }
            let (page, perPage) = Self.pageParams(parsed.query)
            return unwrap(await call(node.commitsJSON(
                rid: rid, parent: parent, page: UInt32(page), perPage: UInt32(perPage)
            )))

        case "stats":
            guard parsed.segments.count == 3, parsed.segments[1] == "tree",
                  Self.isRevision(parsed.segments[2]) else {
                return (400, ["error": "invalid stats path"])
            }
            return unwrap(await call(node.repoStatsJSON(rid: rid, revision: parsed.segments[2])))

        case "remotes":
            return unwrap(await call(node.remotesJSON(rid: rid)))

        case "issues":
            guard parsed.segments.count <= 2 else {
                return (400, ["error": "invalid issue path"])
            }
            if let id = revision {
                return unwrap(await call(node.issueJSON(rid: rid, issueId: id)))
            }
            return paginated(await call(node.issuesJSON(rid: rid)), query: parsed.query)

        case "patches":
            guard parsed.segments.count <= 2 else {
                return (400, ["error": "invalid patch path"])
            }
            if let id = revision {
                return unwrap(await call(node.patchJSON(rid: rid, patchId: id)))
            }
            return paginated(await call(node.patchesJSON(rid: rid)), query: parsed.query)

        default:
            return (404, ["error": "unsupported endpoint: \(section ?? "")"])
        }
    }

    /// Repo metadata in radicle-httpd's `payloads` shape, synthesized
    /// from the flat embedded `repoInfo` — byte-parity with desktop's
    /// `buildRepoMeta`.
    private func buildRepoMeta(rid: String, info: Any) async -> (Int, Any) {
        let flat = info as? [String: Any] ?? [:]
        var seeding = 0
        if case .ok(let seedersObj) = await call(services.node.seedersJSON(rid: rid)),
           let count = (seedersObj as? [String: Any])?["seeding"] as? Int {
            seeding = count
        }
        return (200, [
            "rid": flat["rid"] as? String ?? rid,
            "payloads": [
                "xyz.radicle.project": [
                    "data": [
                        "name": flat["name"] as Any? ?? NSNull(),
                        "description": flat["description"] as Any? ?? NSNull(),
                        "defaultBranch": flat["defaultBranch"] as Any? ?? NSNull(),
                    ],
                    "meta": [
                        "head": flat["head"] as Any? ?? NSNull(),
                        "issues": ["open": flat["issuesOpen"] as Any? ?? NSNull()],
                        "patches": ["open": flat["patchesOpen"] as Any? ?? NSNull()],
                    ],
                ],
            ],
            "delegates": flat["delegates"] as? [Any] ?? [],
            "threshold": flat["threshold"] as Any? ?? 1,
            "visibility": flat["visibility"] as Any? ?? ["type": "public"],
            "seeding": seeding,
        ])
    }

    private static let readmeCandidates = [
        "README.md", "README.markdown", "README.txt", "README", "readme.md",
    ]

    /// First readme blob at the repository root for the revision, shaped
    /// like a blob response plus `path`; 404 when none exists.
    private func readme(rid: String, revision: String) async -> (Int, Any) {
        let treeResult = await call(services.node.treeAtJSON(rid: rid, revision: revision, path: ""))
        guard case .ok(let tree) = treeResult else { return treeResult.errorResponse }
        let entries = (tree as? [String: Any])?["entries"] as? [[String: Any]] ?? []
        let blobNames = Set(entries.filter { $0["kind"] as? String == "blob" }
            .compactMap { $0["name"] as? String })
        for candidate in Self.readmeCandidates where blobNames.contains(candidate) {
            let blobResult = await call(
                services.node.blobAtJSON(rid: rid, revision: revision, path: candidate)
            )
            guard case .ok(let blob) = blobResult else { return blobResult.errorResponse }
            var shaped = blob as? [String: Any] ?? [:]
            shaped["path"] = candidate
            return (200, shaped)
        }
        return (404, ["error": "no readme"])
    }

    // MARK: - JSON plumbing

    /// Outcome of one embedded call: parsed success payload, or the
    /// `{error}` mapped to a status the way desktop's catch does —
    /// not-found phrasing → 404, everything else → 500.
    private enum CallResult {
        case ok(Any)
        case failed(Int, String)

        var errorResponse: (Int, Any) {
            if case .failed(let status, let message) = self {
                return (status, ["error": message])
            }
            return (500, ["error": "internal error"])
        }
    }

    private func call(_ json: String) -> CallResult {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return .failed(500, "undecodable node response")
        }
        if let dict = object as? [String: Any], let message = dict["error"] as? String {
            let missing = message.range(
                of: "not found|does not exist|NotFound",
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            return .failed(missing ? 404 : 500, message)
        }
        return .ok(object)
    }

    private func unwrap(_ result: CallResult) -> (Int, Any) {
        switch result {
        case .ok(let object): return (200, object)
        case .failed: return result.errorResponse
        }
    }

    /// Desktop's `paginate`: optional `status` filter on
    /// `item.state.status`, then page/perPage slicing (defaults 0/30,
    /// perPage capped at 100).
    private func paginated(_ result: CallResult, query: [String: String]) -> (Int, Any) {
        guard case .ok(let object) = result else { return result.errorResponse }
        guard let items = object as? [[String: Any]] else { return (200, object) }
        let filtered: [[String: Any]]
        if let status = query["status"], !status.isEmpty {
            filtered = items.filter {
                (($0["state"] as? [String: Any])?["status"] as? String) == status
            }
        } else {
            filtered = items
        }
        let (page, perPage) = Self.pageParams(query)
        let start = min(page * perPage, filtered.count)
        let end = min(start + perPage, filtered.count)
        return (200, Array(filtered[start..<end]))
    }

    nonisolated static func pageParams(_ query: [String: String]) -> (page: Int, perPage: Int) {
        let page = min(1_000_000, max(0, Int(query["page"] ?? "") ?? 0))
        let perPage = min(100, max(1, Int(query["perPage"] ?? "") ?? 30))
        return (page, perPage)
    }

    // MARK: - Responses

    private func respondJSON(
        _ task: WKURLSchemeTask, key: ObjectIdentifier, status: Int,
        object: Any, headOnly: Bool
    ) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        respond(task, key: key, status: status, body: headOnly ? Data() : body, headOnly: headOnly)
    }

    private func respond(
        _ task: WKURLSchemeTask, key: ObjectIdentifier, status: Int,
        body: Data, headOnly: Bool
    ) {
        guard liveTasks.contains(key), let url = task.request.url else { return }
        liveTasks.remove(key)
        var headers = Self.corsHeaders
        headers["Content-Type"] = "application/json; charset=utf-8"
        guard let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        ) else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(body) // WKURLSchemeTask contract: body call before didFinish
        task.didFinish()
    }
}
