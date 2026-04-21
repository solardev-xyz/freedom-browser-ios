import Foundation

enum BrowserURL: Hashable {
    case bzz(URL)
    case web(URL)

    var url: URL {
        switch self {
        case .bzz(let u), .web(let u): return u
        }
    }

    /// Wrap an already-valid URL in the right case based on its scheme.
    /// Returns nil if the scheme isn't bzz/http/https.
    static func classify(_ url: URL) -> BrowserURL? {
        switch url.scheme?.lowercased() {
        case "bzz": return .bzz(url)
        case "http", "https": return .web(url)
        default: return nil
        }
    }

    static func parse(_ input: String) -> BrowserURL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let classified = classify(url) {
            return classified
        }

        if SwarmRef.isValid(trimmed), let url = URL(string: "bzz://\(trimmed)") {
            return .bzz(url)
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
}
