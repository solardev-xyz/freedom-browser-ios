import Foundation

enum BrowserURL: Hashable {
    case bzz(URL)
    case ipfs(URL)
    case ipns(URL)
    case web(URL)
    case ens(name: String)

    /// URL for display / storage / sharing. ENS names encode as the
    /// `ens://` pseudo-scheme so revisits (from history/bookmarks) route
    /// back through the resolver and pick up any content-hash rotation.
    var url: URL {
        switch self {
        case .bzz(let u), .ipfs(let u), .ipns(let u), .web(let u): return u
        case .ens(let name): return URL(string: "ens://\(name)")!
        }
    }

    /// Wrap an already-valid URL in the right case based on its scheme.
    /// Returns nil if the scheme isn't one we know.
    static func classify(_ url: URL) -> BrowserURL? {
        switch url.scheme?.lowercased() {
        case "bzz": return .bzz(url)
        case "ipfs": return .ipfs(url)
        case "ipns": return .ipns(url)
        case "http", "https":
            // A `.eth` hostname has no DNS equivalent — treat as ENS,
            // regardless of scheme the user happened to type.
            if let host = url.host, host.hasSuffix(".eth") {
                return .ens(name: host.lowercased())
            }
            return .web(url)
        case "ens":
            guard let host = url.host else { return nil }
            return .ens(name: host.lowercased())
        default: return nil
        }
    }

    static func parse(_ input: String) -> BrowserURL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let classified = classify(url) {
            return classified
        }

        // Bare ENS name like "vitalik.eth" (case-insensitive).
        if trimmed.lowercased().hasSuffix(".eth"), !trimmed.contains(" ") {
            return .ens(name: trimmed.lowercased())
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

        if looksLikeHostname(trimmed), let url = URL(string: "https://\(trimmed)") {
            return .web(url)
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
