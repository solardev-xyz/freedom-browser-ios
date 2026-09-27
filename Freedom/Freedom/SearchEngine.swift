import Foundation

/// Address-bar web search — desktop `search-utils.js` parity. Typed input
/// that is not a URL, a hash, a name or a hostname goes to the configured
/// engine instead of being rejected.
enum SearchEngine: String, CaseIterable, Identifiable, Sendable {
    case google, duckduckgo, bing, brave, ecosia, startpage

    var id: String { rawValue }

    static let `default`: SearchEngine = .duckduckgo
    /// The id that selects the user's own template (`SettingsStore.customSearchTemplate`).
    static let customID = "custom"
    static let placeholder = "{searchTerms}"

    var label: String {
        switch self {
        case .google: "Google"
        case .duckduckgo: "DuckDuckGo"
        case .bing: "Bing"
        case .brave: "Brave Search"
        case .ecosia: "Ecosia"
        case .startpage: "Startpage"
        }
    }

    /// OpenSearch-style template (same URLs as desktop).
    var template: String {
        switch self {
        case .google: "https://www.google.com/search?q={searchTerms}"
        case .duckduckgo: "https://duckduckgo.com/?q={searchTerms}"
        case .bing: "https://www.bing.com/search?q={searchTerms}"
        case .brave: "https://search.brave.com/search?q={searchTerms}"
        case .ecosia: "https://www.ecosia.org/search?q={searchTerms}"
        case .startpage: "https://www.startpage.com/sp/search?query={searchTerms}"
        }
    }

    /// Canonicalize the familiar `%s` alias to `{searchTerms}` and check the
    /// template can only reach a web search endpoint: exactly one
    /// placeholder, HTTPS (or plain HTTP to loopback), no credentials, at
    /// most 2048 characters. Nil means "not a usable template".
    static func normalizeTemplate(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2048 else { return nil }
        let openSearch = trimmed.components(separatedBy: placeholder).count - 1
        let percent = trimmed.components(separatedBy: "%s").count - 1
        guard openSearch + percent == 1 else { return nil }
        let normalized = percent == 1 ? trimmed.replacingOccurrences(of: "%s", with: placeholder) : trimmed
        guard let probe = URL(string: normalized.replacingOccurrences(of: placeholder, with: "test")),
              let scheme = probe.scheme?.lowercased(), let host = probe.host?.lowercased()
        else { return nil }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && loopback) else { return nil }
        guard probe.user == nil, probe.password == nil else { return nil }
        return normalized
    }

    /// The engine `providerID` resolves to: a built-in, the custom template
    /// when it validates, else the default. An unknown or stale id can never
    /// break address-bar search.
    static func resolve(providerID: String, customName: String, customTemplate: String) -> (label: String, template: String) {
        if let builtIn = SearchEngine(rawValue: providerID) { return (builtIn.label, builtIn.template) }
        if providerID == customID, let template = normalizeTemplate(customTemplate) {
            let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return (name, template) }
        }
        return (SearchEngine.default.label, SearchEngine.default.template)
    }

    /// The results URL for `query`, or nil for empty input.
    static func buildURL(query: String, providerID: String, customName: String = "", customTemplate: String = "") -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let (_, template) = resolve(providerID: providerID, customName: customName, customTemplate: customTemplate)
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: template.replacingOccurrences(of: placeholder, with: encoded))
    }
}
