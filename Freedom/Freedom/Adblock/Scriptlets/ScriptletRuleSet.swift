import Foundation

/// `scriptlets.json` from freedom-adblock-service: every `+js(…)` rule of the
/// filter lists, already parsed (names canonical, args unescaped, hostnames
/// lowercased and punycoded). Format 1 is the only one this build reads.
nonisolated struct ScriptletRuleSet: Decodable, Sendable {
    static let supportedFormat = 1

    let format: Int
    let rules: [Rule]

    nonisolated struct Rule: Decodable, Sendable, Hashable {
        let listId: String
        /// "scriptlet" or "surrogate" (a redirect resource injected verbatim).
        let kind: String
        /// Canonical scriptlet name without `.js`, or the surrogate's exact
        /// resource name. Empty on the `#@#+js()` "disable all" exception.
        let scriptlet: String
        let args: [String]
        let domains: [String]
        let excludeDomains: [String]
        /// Subframe rules (`host>>##+js(…)`): only inside frames whose parent
        /// matches. This build injects into top-level pages only.
        let parentDomains: [String]?
        let exception: Bool
    }

    static func decode(_ data: Data) throws -> ScriptletRuleSet {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let set = try decoder.decode(ScriptletRuleSet.self, from: data)
        guard set.format == supportedFormat else {
            throw AdblockError.unsupportedFormat("scriptlets.json format \(set.format)")
        }
        return set
    }
}

/// Which rules apply to a page. Hostname semantics follow
/// @ghostery/adblocker (desktop): a rule's plain hostname matches the page's
/// registrable domain or any longer suffix of its host; an entity (`google.*`)
/// matches the host without its public suffix, label by label; `~` exclusions
/// veto either way.
nonisolated struct ScriptletIndex: Sendable {
    let rules: [ScriptletRuleSet.Rule]
    private let constraints: [Constraint]
    private let byHostname: [String: [Int]]
    private let byEntity: [String: [Int]]
    /// Rules without a positive hostname (only exceptions, in practice).
    private let unconstrained: [Int]

    private nonisolated struct Constraint: Sendable {
        let hostnames: Set<String>
        let entities: Set<String>
        let notHostnames: Set<String>
        let notEntities: Set<String>
    }

    init(ruleSet: ScriptletRuleSet) {
        // Top-level pages only, and only the kinds this build can inject.
        let rules = ruleSet.rules.filter {
            $0.parentDomains == nil && ($0.kind == "scriptlet" || $0.kind == "surrogate")
        }
        var constraints: [Constraint] = []
        var byHostname: [String: [Int]] = [:]
        var byEntity: [String: [Int]] = [:]
        var unconstrained: [Int] = []
        constraints.reserveCapacity(rules.count)
        for (i, rule) in rules.enumerated() {
            let (hostnames, entities) = Self.split(rule.domains)
            let (notHostnames, notEntities) = Self.split(rule.excludeDomains)
            constraints.append(Constraint(
                hostnames: hostnames, entities: entities,
                notHostnames: notHostnames, notEntities: notEntities
            ))
            for hostname in hostnames { byHostname[hostname, default: []].append(i) }
            for entity in entities { byEntity[entity, default: []].append(i) }
            if hostnames.isEmpty && entities.isEmpty { unconstrained.append(i) }
        }
        self.rules = rules
        self.constraints = constraints
        self.byHostname = byHostname
        self.byEntity = byEntity
        self.unconstrained = unconstrained
    }

    /// `google.*` → entity `google`; anything else is a plain hostname.
    private static func split(_ domains: [String]) -> (hostnames: Set<String>, entities: Set<String>) {
        var hostnames = Set<String>()
        var entities = Set<String>()
        for domain in domains {
            if domain.hasSuffix(".*") {
                entities.insert(String(domain.dropLast(2)))
            } else {
                hostnames.insert(domain)
            }
        }
        return (hostnames, entities)
    }

    /// Indices of the rules matching `host`, in list order.
    func matches(host: String, suffixes psl: PublicSuffixList) -> [Int] {
        let domain = psl.domain(of: host)
        let hostnames = Self.hostnameSuffixes(host, domain: domain)
        let entities = Self.entitySuffixes(host, domain: domain)

        var candidates = Set(unconstrained)
        for hostname in hostnames { candidates.formUnion(byHostname[hostname] ?? []) }
        for entity in entities { candidates.formUnion(byEntity[entity] ?? []) }

        return candidates.filter { i in
            let c = constraints[i]
            if hostnames.contains(where: c.notHostnames.contains) { return false }
            if entities.contains(where: c.notEntities.contains) { return false }
            if c.hostnames.isEmpty && c.entities.isEmpty { return true }
            return hostnames.contains(where: c.hostnames.contains) || entities.contains(where: c.entities.contains)
        }.sorted()
    }

    /// Ghostery's `getHostnameHashesFromLabelsBackward`: the registrable
    /// domain and every longer suffix up to the full host. Without a domain
    /// (IP, bare public suffix) every suffix, down to the last label.
    static func hostnameSuffixes(_ host: String, domain: String?) -> [String] {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let minLabels = domain.map { $0.split(separator: ".").count } ?? 1
        guard labels.count >= minLabels else { return [host] }
        return (0...(labels.count - minLabels)).map { labels[$0...].joined(separator: ".") }
    }

    /// Ghostery's `getEntityHashesFromLabelsBackward`: the host minus its
    /// public suffix, every label suffix of that (`www.google.co.uk` →
    /// `google`, `www.google`).
    static func entitySuffixes(_ host: String, domain: String?) -> [String] {
        guard let domain, let dot = domain.firstIndex(of: ".") else { return [] }
        let publicSuffix = domain[domain.index(after: dot)...]
        guard host.count > publicSuffix.count + 1 else { return [] }
        let withoutSuffix = host.dropLast(publicSuffix.count + 1)
        let labels = withoutSuffix.split(separator: ".", omittingEmptySubsequences: false)
        return labels.indices.map { labels[$0...].joined(separator: ".") }
    }
}
