import Foundation

/// ICANN public suffixes (`Resources/public_suffix_list.dat`, refreshed by
/// `scripts/adblock/update-public-suffix.py`). Scriptlet rules can name an
/// entity — `google.*` means Google under any public suffix — and matching
/// that needs the page's registrable domain. Mirrors what desktop's
/// @ghostery/adblocker gets from tldts: ICANN rules only, an unlisted TLD is
/// itself a public suffix (the implicit `*` rule), IP addresses have no
/// domain. Hosts are expected lowercased and punycoded, as WebKit gives them.
nonisolated struct PublicSuffixList: Sendable {
    private let rules: Set<String>
    /// `kawasaki.jp` for the rule `*.kawasaki.jp`.
    private let wildcards: Set<String>
    /// `city.kawasaki.jp` for the rule `!city.kawasaki.jp`.
    private let exceptions: Set<String>

    init(text: String) {
        var rules = Set<String>()
        var wildcards = Set<String>()
        var exceptions = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let rule = line.trimmingCharacters(in: .whitespaces)
            if rule.isEmpty || rule.hasPrefix("//") { continue }
            if rule.hasPrefix("!") {
                exceptions.insert(String(rule.dropFirst()))
            } else if rule.hasPrefix("*.") {
                wildcards.insert(String(rule.dropFirst(2)))
            } else {
                rules.insert(rule)
            }
        }
        self.rules = rules
        self.wildcards = wildcards
        self.exceptions = exceptions
    }

    static func bundled() throws -> PublicSuffixList {
        guard let url = Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat") else {
            throw AdblockError.resourceMissing("public_suffix_list.dat")
        }
        return PublicSuffixList(text: try String(contentsOf: url, encoding: .utf8))
    }

    /// The longest matching suffix rule, exceptions first, else the last label.
    func publicSuffix(of host: String) -> String {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        for start in labels.indices {
            let candidate = labels[start...].joined(separator: ".")
            if exceptions.contains(candidate) {
                return labels[(start + 1)...].joined(separator: ".")
            }
            if rules.contains(candidate) { return candidate }
            if start + 1 < labels.count, wildcards.contains(labels[(start + 1)...].joined(separator: ".")) {
                return candidate
            }
        }
        return labels.last.map(String.init) ?? host
    }

    /// The registrable domain (public suffix plus one label), or nil for an
    /// IP address or a host that is itself a public suffix.
    func domain(of host: String) -> String? {
        if host.isEmpty || Self.isIPAddress(host) { return nil }
        let suffix = publicSuffix(of: host)
        guard host.count > suffix.count, host.hasSuffix("." + suffix) else { return nil }
        let rest = host.dropLast(suffix.count + 1)
        let label = rest.split(separator: ".").last.map(String.init) ?? String(rest)
        return label + "." + suffix
    }

    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
