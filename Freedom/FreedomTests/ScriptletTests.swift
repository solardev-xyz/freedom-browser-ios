import CryptoKit
import XCTest
@testable import Freedom

/// uBlock-style scriptlets: public suffixes, which rules apply to a page,
/// and byte parity of the injected code with desktop's @ghostery/adblocker.
final class ScriptletTests: XCTestCase {

    // MARK: - Public suffixes

    func testRegistrableDomainsFollowICANNSuffixes() throws {
        let psl = try PublicSuffixList.bundled()
        XCTAssertEqual(psl.domain(of: "www.google.co.uk"), "google.co.uk")
        XCTAssertEqual(psl.domain(of: "example.com"), "example.com")
        // ICANN only, like desktop's tldts: github.io is a registrable domain.
        XCTAssertEqual(psl.domain(of: "foo.github.io"), "github.io")
        XCTAssertEqual(psl.domain(of: "a.b.kawasaki.jp"), "a.b.kawasaki.jp", "*.kawasaki.jp")
        XCTAssertEqual(psl.domain(of: "www.city.kawasaki.jp"), "city.kawasaki.jp", "!city.kawasaki.jp")
        XCTAssertEqual(psl.domain(of: "foo.bar.notatld"), "bar.notatld", "unlisted TLD is a suffix")
        XCTAssertNil(psl.domain(of: "co.uk"))
        XCTAssertNil(psl.domain(of: "localhost"))
        XCTAssertNil(psl.domain(of: "192.168.1.1"))
    }

    // MARK: - Matching

    /// Self-written stand-ins for resources.json: a scriptlet with a
    /// dependency chain, an alias, a JavaScript surrogate and an image.
    private static let resourcesJSON = """
    {"scriptlets":[
     {"name":"a.js","aliases":["alias-a.js"],"body":"function a(x){}","dependencies":["dep1.fn"]},
     {"name":"dep1.fn","aliases":[],"body":"function dep1(){}","dependencies":["dep2.fn"]},
     {"name":"dep2.fn","aliases":[],"body":"function dep2(){}","dependencies":[]},
     {"name":"b.js","aliases":[],"body":"function b(){}","dependencies":[]}],
     "redirects":[
     {"name":"sur.js","aliases":[],"contentType":"application/javascript","body":"(function(){})();"},
     {"name":"img.png","aliases":[],"contentType":"image/png;base64","body":"AA=="}]}
    """

    private static func rule(
        _ list: String, _ name: String, _ args: [String] = [], domains: [String] = [],
        exclude: [String] = [], parents: [String]? = nil, kind: String = "scriptlet", exception: Bool = false
    ) -> [String: Any] {
        var rule: [String: Any] = [
            "list_id": list, "kind": kind, "scriptlet": name, "args": args,
            "domains": domains, "exclude_domains": exclude, "exception": exception,
        ]
        if let parents { rule["parent_domains"] = parents }
        return rule
    }

    private func engine() throws -> ScriptletEngine {
        let rules: [[String: Any]] = [
            Self.rule("easylist", "a", ["x"], domains: ["example.com"]),
            Self.rule("ublock", "b", domains: ["google.*"], exclude: ["mail.google.com"]),
            Self.rule("ublock", "a", ["x"], domains: ["sub.example.com"]),
            Self.rule("ublock", "b", domains: ["google.co.uk"], exception: true),
            Self.rule("easylist-annoyances", "", domains: ["quiet.example.com"], exception: true),
            Self.rule("ublock", "sur.js", domains: ["example.org"], kind: "surrogate"),
            Self.rule("ublock", "a", ["frame"], parents: ["example.net"]),
            Self.rule("easyprivacy", "b", domains: ["10.0.0.1"]),
            Self.rule("ublock", "a", ["y"], kind: "redirect-rule"),
        ]
        let data = try JSONSerialization.data(withJSONObject: ["format": 1, "rules": rules])
        return ScriptletEngine(
            ruleSet: try ScriptletRuleSet.decode(data),
            resources: try ScriptletResources(data: Data(Self.resourcesJSON.utf8)),
            suffixes: try PublicSuffixList.bundled()
        )
    }

    private static let allLists: Set<String> = ["easylist", "ublock", "easyprivacy", "easylist-cookies", "easylist-annoyances"]

    private func names(_ engine: ScriptletEngine, _ host: String, lists: Set<String> = allLists) -> [String] {
        engine.injections(forHost: host, enabledLists: lists).map { "\($0.scriptlet)(\($0.args.joined(separator: ",")))" }
    }

    func testHostnameEntityExclusionAndExceptionSemantics() throws {
        let e = try engine()
        XCTAssertEqual(names(e, "example.com"), ["a(x)"])
        XCTAssertEqual(names(e, "sub.example.com"), ["a(x)"], "the same injection from two rules runs once")
        XCTAssertEqual(names(e, "www.google.de"), ["b()"], "entity google.* under any public suffix")
        XCTAssertEqual(names(e, "mail.google.com"), [], "~mail.google.com vetoes")
        XCTAssertEqual(names(e, "google.co.uk"), [], "#@#+js(b) cancels it")
        XCTAssertEqual(names(e, "google.evil.com"), [], "google.* is not any host containing google")
        XCTAssertEqual(names(e, "quiet.example.com"), [], "#@#+js() cancels everything")
        XCTAssertEqual(names(e, "quiet.example.com", lists: ["easylist"]), ["a(x)"],
                       "an exception only counts while its list is on")
        XCTAssertEqual(names(e, "www.google.de", lists: ["easylist"]), [], "uBlock rules need the uBlock list")
        XCTAssertEqual(names(e, "10.0.0.1"), ["b()"], "IP hosts match literally")
        XCTAssertEqual(names(e, "example.net"), [], "subframe rules don't touch top-level pages")
        XCTAssertEqual(e.ruleCount, 7, "subframe rules and unknown kinds are skipped")
    }

    func testPageScriptWrapsEachInjection() throws {
        let e = try engine()
        let surrogate = try XCTUnwrap(e.script(forHost: "example.org", enabledLists: Self.allLists))
        XCTAssertEqual(surrogate.source, "(function () {\ntry {\n(function(){})();\n} catch (e) {}\n})();")
        XCTAssertEqual(surrogate.count, 1)
        XCTAssertNil(e.script(forHost: "nothing.test", enabledLists: Self.allLists))
    }

    func testAssemblyMatchesGhosteryShape() throws {
        let resources = try ScriptletResources(data: Data(Self.resourcesJSON.utf8))
        let script = try XCTUnwrap(resources.script(name: "alias-a", args: ["1"]))
        XCTAssertEqual(script, "if (typeof scriptletGlobals === 'undefined') { var scriptletGlobals = {}; };"
            + "function dep1(){};function dep2(){};"
            + "(function a(x){})(...[`1`,`{{2}}`,`{{3}}`,`{{4}}`,`{{5}}`,`{{6}}`,`{{7}}`,`{{8}}`,`{{9}}`,`{{10}}`]"
            + ".filter((a,i) => a !== '{{'+(i+1)+'}}').map((a) => decodeURIComponent(a)))")
        XCTAssertNil(resources.script(name: "dep1.fn", args: []), "helpers are not injectable")
        XCTAssertNil(resources.script(name: "img.png", args: []), "only JavaScript surrogates")
    }

    func testReplacementFollowsJavaScriptSemantics() {
        XCTAssertEqual(ScriptletResources.replaceFirst("{{1}}", in: "a{{1}}b{{1}}", with: "$&-$$-$`-$'-$1-$"),
                       "a{{1}}-$-a-b{{1}}-$1-$b{{1}}")
        XCTAssertEqual(ScriptletResources.escapeRegexCharacters("a.b$c\\d{e}"), "a\\.b\\$c\\\\d\\{e\\}")
        XCTAssertEqual(ScriptletResources.replaceFirst("{{9}}", in: "x", with: "y"), "x")
    }

    // MARK: - Parity with desktop (bundled data)

    private struct Vectors: Decodable {
        struct Vector: Decodable { let rule: String; let sha256: String }
        struct Synthetic: Decodable { let kind: String; let scriptlet: String; let args: [String]; let sha256: String }
        let resourcesSha256: String
        let vectors: [Vector]
        let synthetic: [Synthetic]
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func bundledFile(_ name: String) throws -> Data {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "adblock")
            ?? Bundle.main.url(forResource: name, withExtension: "json") else {
            throw XCTSkip("\(name).json not bundled (copy the adblock service's out/ into Resources/adblock)")
        }
        return try Data(contentsOf: url)
    }

    /// Golden hashes from @ghostery/adblocker 2.18.2's own
    /// `CosmeticFilter.getScript`, fed the same (name, args) — see
    /// Fixtures/adblock-scriptlet-vectors.json. Real rules are referenced by
    /// a hash of their content so no list data lives in the repo.
    func testInjectedCodeIsByteIdenticalToDesktop() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "adblock-scriptlet-vectors", withExtension: "json"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let vectors = try decoder.decode(Vectors.self, from: Data(contentsOf: fixture))
        let resourcesData = try bundledFile("resources")
        guard Self.sha256(resourcesData) == vectors.resourcesSha256 else {
            throw XCTSkip("bundled resources.json is not the pinned build the vectors were made from")
        }
        let resources = try ScriptletResources(data: resourcesData)

        for vector in vectors.synthetic {
            let script = try XCTUnwrap(resources.script(name: vector.scriptlet, args: vector.args))
            XCTAssertEqual(Self.sha256(Data(script.utf8)), vector.sha256, "\(vector.scriptlet) \(vector.args)")
        }

        let ruleSet = try ScriptletRuleSet.decode(bundledFile("scriptlets"))
        var byKey: [String: ScriptletRuleSet.Rule] = [:]
        for rule in ruleSet.rules {
            let key = ([rule.kind, rule.scriptlet] + rule.args).joined(separator: "\u{0}")
            byKey[Self.sha256(Data(key.utf8))] = rule
        }
        var checked = 0
        for vector in vectors.vectors {
            guard let rule = byKey[vector.rule] else { continue }
            let script = try XCTUnwrap(resources.script(name: rule.scriptlet, args: rule.args), rule.scriptlet)
            XCTAssertEqual(Self.sha256(Data(script.utf8)), vector.sha256, "\(rule.scriptlet) \(rule.args)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, vectors.vectors.count / 2,
                             "most vector rules should still be in the bundled lists")
    }

    /// The real bundle: YouTube's mobile site gets its ad-pruning scriptlets,
    /// and the per-navigation cost stays small. Prints the numbers.
    func testBundledScriptletsCoverYouTubeQuickly() throws {
        let scriptletsData = try bundledFile("scriptlets")
        let resourcesData = try bundledFile("resources")
        let suffixes = try PublicSuffixList.bundled()

        let loadStart = ContinuousClock.now
        let engine = ScriptletEngine(
            ruleSet: try ScriptletRuleSet.decode(scriptletsData),
            resources: try ScriptletResources(data: resourcesData),
            suffixes: suffixes
        )
        let loadTime = ContinuousClock.now - loadStart

        let youtube = try XCTUnwrap(engine.script(forHost: "m.youtube.com", enabledLists: Self.allLists))
        XCTAssertGreaterThanOrEqual(youtube.count, 5)
        XCTAssertNil(engine.script(forHost: "m.youtube.com", enabledLists: ["easyprivacy"]),
                     "with Block ads off YouTube gets nothing")

        let hosts = ["m.youtube.com", "www.youtube.com", "www.reddit.com", "www.spiegel.de", "en.wikipedia.org",
                     "www.google.com", "news.ycombinator.com", "www.nytimes.com", "github.com", "example.com"]
        let rounds = 100
        let lookupStart = ContinuousClock.now
        var bytes = 0
        for _ in 0..<rounds {
            for host in hosts { bytes += engine.script(forHost: host, enabledLists: Self.allLists)?.source.utf8.count ?? 0 }
        }
        let perLookup = (ContinuousClock.now - lookupStart) / (rounds * hosts.count)
        print("[scriptlets] \(engine.ruleCount) rules, load \(loadTime), per navigation \(perLookup), m.youtube.com \(youtube.count) scriptlets \(youtube.source.utf8.count / 1024) KB")
        XCTAssertLessThan(perLookup, .milliseconds(5))
        XCTAssertGreaterThan(bytes, 0)
    }
}
