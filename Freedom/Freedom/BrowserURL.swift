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
    case ens(name: String, path: String = "")

    /// URL for display / storage / sharing. ENS names encode as the
    /// `ens://` pseudo-scheme so revisits (from history/bookmarks) route
    /// back through the resolver and pick up any content-hash rotation.
    var url: URL {
        switch self {
        case .bzz(let u), .ipfs(let u), .ipns(let u), .web(let u): return u
        case .ens(let name, let path):
            // Empty path emits `ens://name` to preserve the historical
            // display form. Non-empty path is normalized to start with
            // `/` so the URL parses regardless of how callers stored it.
            let suffix: String
            if path.isEmpty {
                suffix = ""
            } else if path.hasPrefix("/") || path.hasPrefix("?") || path.hasPrefix("#") {
                suffix = path
            } else {
                suffix = "/" + path
            }
            return URL(string: "ens://\(name)\(suffix)")!
        }
    }

    /// Wrap an already-valid URL in the right case based on its scheme.
    /// Returns nil if the scheme isn't one we know.
    static func classify(_ url: URL) -> BrowserURL? {
        // A `.eth` hostname has no DNS equivalent — route through ENS
        // regardless of the codec scheme the URL was stored under.
        // Without this, a restored tab / bookmark / history entry of
        // `bzz://vitalik.eth/blog` skips the BrowserTab-level ENS resolve,
        // leaving `currentTrust` nil and the address-bar shield blank.
        if let name = url.ensName {
            return .ens(name: name, path: extractTail(url))
        }
        switch url.scheme?.lowercased() {
        case "bzz": return .bzz(url)
        case "ipfs": return .ipfs(url)
        case "ipns": return .ipns(url)
        case "http", "https":
            return .web(url)
        case "ens":
            guard let host = url.host?.lowercased() else { return nil }
            return .ens(name: host, path: extractTail(url))
        default: return nil
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

        if let url = URL(string: trimmed), let classified = classify(url) {
            return classified
        }

        // Bare Ethereum name like "vitalik.eth" / "wns.wei" / "apoorv.gwei"
        // (case-insensitive).
        let lowerTrimmed = trimmed.lowercased()
        if !trimmed.contains(" "),
           NameSystem.navigableSuffixes.contains(where: lowerTrimmed.hasSuffix) {
            return .ens(name: lowerTrimmed)
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
