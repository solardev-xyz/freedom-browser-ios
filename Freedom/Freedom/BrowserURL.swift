import Foundation

enum BrowserURL: Hashable {
    case bzz(URL)
    case ipfs(URL)
    case ipns(URL)
    case web(URL)
    /// `path` is the percent-encoded tail of the source URL: a path segment
    /// possibly followed by `?query` and/or `#fragment`. `""` = root.
    /// `BrowserTab.resolveAndLoad` re-attaches this to the resolved
    /// `<codec>://name/` URI so deep links survive ENS routing — a
    /// bookmark of `bzz://vitalik.eth/blog/post1?q=1#anchor` reaches
    /// `/blog/post1?q=1#anchor` on the resolved transport, not root.
    /// `codec` is the transport the user asserted by typing or clicking
    /// `bzz://`, `ipfs://` or `ipns://` in front of the name (desktop
    /// "typed scheme is an assertion"): resolution must land on that
    /// codec or the tab gates with "resolves to X, not Y". Bare names,
    /// `ens://` and `https://` forms assert nothing.
    case ens(name: String, path: String = "", codec: ENSContentCodec? = nil)
    /// Tezos Domains name (`name.tez`), resolved on Tezos to a website
    /// record. Same tail shape as `.ens`; displays as `tez://name`.
    case tez(name: String, path: String = "")
    /// Contract-hosted app (ERC-8244). `path` is the same percent-encoded
    /// tail shape as `.ens`; the app's client-side router sees it.
    case onchain(app: OnchainAppRef, path: String = "")

    /// URL for display / storage / sharing. ENS names encode as the
    /// `ens://` pseudo-scheme so revisits (from history/bookmarks) route
    /// back through the resolver and pick up any content-hash rotation.
    var url: URL {
        switch self {
        case .bzz(let u), .ipfs(let u), .ipns(let u), .web(let u): return u
        case .onchain(let app, let path): return app.displayURL(tail: path)
        case .ens(let name, let path, _):
            return URL(string: "ens://\(name)\(Self.suffix(path))")!
        case .tez(let name, let path):
            return URL(string: "tez://\(name)\(Self.suffix(path))")!
        }
    }

    /// Empty path emits `scheme://name` to preserve the historical
    /// display form. Non-empty path is normalized to start with `/` so
    /// the URL parses regardless of how callers stored it.
    private static func suffix(_ path: String) -> String {
        if path.isEmpty { return "" }
        if path.hasPrefix("/") || path.hasPrefix("?") || path.hasPrefix("#") { return path }
        return "/" + path
    }

    /// A name the tab resolves before loading (ENS family or Tezos Domains).
    var isName: Bool {
        switch self {
        case .ens, .tez: true
        default: false
        }
    }

    /// The name behind `.ens` / `.tez`, else nil.
    var name: String? {
        switch self {
        case .ens(let name, _, _), .tez(let name, _): name
        default: nil
        }
    }

    /// Wrap an already-valid URL in the right case based on its scheme.
    /// Returns nil if the scheme isn't one we know.
    static func classify(_ url: URL) -> BrowserURL? {
        // A `.tez` host is a Tezos Domains name on any scheme the browser
        // resolves names for (`tez://`, a content scheme, https typed by
        // hand). `ens://name.tez` is deliberately not a name: .tez isn't ENS.
        if let host = url.host(percentEncoded: false)?.lowercased(), TezosDomains.isName(host),
           let scheme = url.scheme?.lowercased(), ["tez", "ipfs", "ipns", "bzz", "http", "https"].contains(scheme) {
            return .tez(name: host, path: extractTail(url))
        }
        // A `.eth` hostname has no DNS equivalent — route through ENS
        // regardless of the codec scheme the URL was stored under.
        // Without this, a restored tab / bookmark / history entry of
        // `bzz://vitalik.eth/blog` skips the BrowserTab-level ENS resolve,
        // leaving `currentTrust` nil and the address-bar shield blank.
        if let name = url.ensName {
            return .ens(name: name, path: extractTail(url), codec: assertedCodec(url))
        }
        switch url.scheme?.lowercased() {
        case OnchainAppRef.scheme:
            // Friendly or canonical form; both collapse to the app.
            guard let (app, tail) = OnchainAppRef.parse(url) else { return nil }
            return .onchain(app: app, path: tail)
        case "bzz": return .bzz(url)
        case "ipfs": return .ipfs(url)
        case "ipns": return .ipns(url)
        case "http", "https":
            return .web(url)
        case "ens":
            // `.tez` is not ENS (desktop rejects `ens://name.tez` too).
            guard let host = url.host?.lowercased(), !TezosDomains.isName(host) else { return nil }
            return .ens(name: host, path: extractTail(url))
        default: return nil
        }
    }

    /// The transport a `<codec>://name` URL asserts; nil for `ens://`,
    /// `https://` and bare names.
    private static func assertedCodec(_ url: URL) -> ENSContentCodec? {
        switch url.scheme?.lowercased() {
        case "bzz": .bzz
        case "ipfs": .ipfs
        case "ipns": .ipns
        default: nil
        }
    }

    /// Glues `URLComponents.percentEncodedPath` + `?query` + `#fragment`
    /// into a single tail string. Returns `""` for URLs with no
    /// path/query/fragment so the `.ens` case can use a clean default.
    private static func extractTail(_ url: URL) -> String {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return ""
        }
        var tail = comps.percentEncodedPath
        if let query = comps.percentEncodedQuery, !query.isEmpty {
            tail += "?\(query)"
        }
        if let fragment = comps.percentEncodedFragment, !fragment.isEmpty {
            tail += "#\(fragment)"
        }
        return tail
    }

    static func parse(_ input: String) -> BrowserURL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Explicit `ens://<name>[/path]` is a request for name resolution
        // whatever the host looks like — a DNS-imported name
        // (`ens://gregskril.com`), an emoji label — so it's parsed here
        // by hand rather than through `URL`, which can't carry a
        // non-ASCII host through `classify` intact.
        if trimmed.lowercased().hasPrefix("ens://") {
            let tail = trimmed.dropFirst("ens://".count)
            let name = tail.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" })
            guard !name.isEmpty, !name.contains(" "), NameSystem.isPotentialEnsName(name),
                  !TezosDomains.isName(name) else { return nil }
            return .ens(name: name.lowercased(), path: String(tail.dropFirst(name.count)))
        }

        if let url = URL(string: trimmed), let classified = classify(url) {
            return classified
        }

        // Bare Ethereum name like "vitalik.eth" / "wns.wei" / "apoorv.gwei"
        // (case-insensitive), optionally with a path tail. Handled before
        // the generic hostname branch because a non-ASCII label
        // (`🦇.eth/blog`) doesn't survive the `https://` round-trip.
        // A bare `name.tez` is a Tezos Domains name the same way.
        if !trimmed.contains(" ") {
            let host = trimmed.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" })
            let lowerHost = host.lowercased()
            if TezosDomains.isName(lowerHost) {
                return .tez(name: lowerHost, path: String(trimmed.dropFirst(host.count)))
            }
            if NameSystem.navigableSuffixes.contains(where: lowerHost.hasSuffix),
               NameSystem.isPotentialEnsName(lowerHost) {
                return .ens(name: lowerHost, path: String(trimmed.dropFirst(host.count)))
            }
        }

        if SwarmRef.isValid(trimmed), let url = URL(string: "bzz://\(trimmed)") {
            return .bzz(url)
        }

        // Bare CID typed at the address bar — heuristic only, full CID
        // validation is left to kubo's gateway. CIDv0 is base58, always
        // 46 chars, starts with "Qm". CIDv1 lowercase base32 starts with
        // "b" (multibase prefix) followed by base32-only chars.
        if isLikelyCIDv0(trimmed) || isLikelyCIDv1Base32(trimmed),
           let url = URL(string: "ipfs://\(trimmed)") {
            return .ipfs(url)
        }

        // Bare hostname-with-path (`vitalik.eth/blog`, `example.com/x`).
        // Wrapping in `https://` then re-classifying picks up the
        // `.eth` rewrite for ENS-host inputs while leaving non-ENS
        // hostnames as plain `.web` — single path for both.
        if looksLikeHostname(trimmed), let url = URL(string: "https://\(trimmed)") {
            return classify(url) ?? .web(url)
        }

        return nil
    }

    private static func looksLikeHostname(_ s: String) -> Bool {
        guard !s.contains(" ") else { return false }
        return s == "localhost" || s.contains(".")
    }

    private static func isLikelyCIDv0(_ s: String) -> Bool {
        guard s.count == 46, s.hasPrefix("Qm") else { return false }
        let base58 = Set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        return s.allSatisfy { base58.contains($0) }
    }

    private static func isLikelyCIDv1Base32(_ s: String) -> Bool {
        // Multibase 'b' = lowercase base32 (RFC 4648). Real CIDv1s are
        // ~59 chars for SHA-256 digests; 50 is a safe lower bound that
        // excludes short 4-char ENS names like `b.eth` etc.
        guard s.count >= 50, s.hasPrefix("b") else { return false }
        let base32 = Set("abcdefghijklmnopqrstuvwxyz234567")
        return s.dropFirst().allSatisfy { base32.contains($0) }
    }
}
