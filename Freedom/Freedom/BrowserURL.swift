import Foundation

enum BrowserURL: Hashable {
    case bzz(URL)
    case web(URL)

    var url: URL {
        switch self {
        case .bzz(let u), .web(let u): return u
        }
    }

    static func parse(_ input: String) -> BrowserURL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let scheme = URL(string: trimmed)?.scheme?.lowercased() {
            if scheme == "bzz", let url = URL(string: trimmed) { return .bzz(url) }
            if scheme == "http" || scheme == "https", let url = URL(string: trimmed) { return .web(url) }
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
