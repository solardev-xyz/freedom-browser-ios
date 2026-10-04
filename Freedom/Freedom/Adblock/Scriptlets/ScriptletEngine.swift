import Foundation

/// The uBlock-style scriptlets a page runs before its own scripts: matches
/// the page's host against `scriptlets.json`, applies the exceptions, and
/// builds one script from `resources.json`. Immutable once loaded; built off
/// the main thread, queried on every top-level navigation.
nonisolated final class ScriptletEngine: Sendable {
    let index: ScriptletIndex
    let resources: ScriptletResources
    private let suffixes: PublicSuffixList

    init(ruleSet: ScriptletRuleSet, resources: ScriptletResources, suffixes: PublicSuffixList) {
        self.index = ScriptletIndex(ruleSet: ruleSet)
        self.resources = resources
        self.suffixes = suffixes
    }

    static func load(scriptlets: URL, resources: URL, suffixes: PublicSuffixList) throws -> ScriptletEngine {
        let ruleSet = try ScriptletRuleSet.decode(Data(contentsOf: scriptlets))
        let resources = try ScriptletResources(data: Data(contentsOf: resources))
        return ScriptletEngine(ruleSet: ruleSet, resources: resources, suffixes: suffixes)
    }

    var ruleCount: Int { index.rules.count }

    /// The injections for `host` from the enabled lists, after exceptions.
    /// Mirrors @ghostery/adblocker's cosmetic matching: an exception
    /// `#@#+js(name, args)` cancels that exact injection, the empty
    /// `#@#+js()` cancels all of them. Identical injections from different
    /// rules run once.
    func injections(forHost host: String, enabledLists: Set<String>) -> [ScriptletRuleSet.Rule] {
        let matched = index.matches(host: host, suffixes: suffixes)
            .map { index.rules[$0] }
            .filter { enabledLists.contains($0.listId) }
        var cancelled = Set<InjectionKey>()
        for rule in matched where rule.exception {
            if rule.scriptlet.isEmpty { return [] }
            cancelled.insert(InjectionKey(rule))
        }
        var seen = Set<InjectionKey>()
        return matched.filter { rule in
            guard !rule.exception else { return false }
            let key = InjectionKey(rule)
            return !cancelled.contains(key) && seen.insert(key).inserted
        }
    }

    /// One script for the page, or nil when nothing applies. Each injection
    /// is wrapped in its own try/catch like desktop (`getScriptlets`), and the
    /// whole thing in a function so `scriptletGlobals` stays off `window`.
    func script(
        forHost host: String, enabledLists: Set<String>,
        including include: (ScriptletRuleSet.Rule) -> Bool = { _ in true }
    ) -> (source: String, count: Int)? {
        let codes = injections(forHost: host, enabledLists: enabledLists)
            .filter(include)
            .compactMap { resources.script(name: $0.scriptlet, args: $0.args) }
        guard !codes.isEmpty else { return nil }
        let body = codes.map { "try {\n\($0)\n} catch (e) {}" }.joined(separator: "\n")
        return ("(function () {\n\(body)\n})();", codes.count)
    }

    private nonisolated struct InjectionKey: Hashable {
        let scriptlet: String
        let args: [String]
        init(_ rule: ScriptletRuleSet.Rule) {
            scriptlet = rule.scriptlet
            args = rule.args
        }
    }
}
