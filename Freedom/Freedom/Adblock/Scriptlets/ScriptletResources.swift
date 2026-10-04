import Foundation

/// uBlock Origin's scriptlets and redirect resources, in the `resources.json`
/// shape @ghostery/adblocker reads (Ghostery's build, pinned by sha256 in the
/// feed manifest; byte-identical to desktop's bundled copy). Turning a rule
/// into code is a straight port of Ghostery's `assembleScript`,
/// `Resources.getScriptlet` and `CosmeticFilter.getScript`, so a page gets the
/// same bytes desktop injects (checked against golden hashes in the tests).
nonisolated struct ScriptletResources: Sendable {
    private nonisolated struct Scriptlet: Decodable {
        let name: String
        let aliases: [String]?
        let body: String
        let dependencies: [String]?
    }

    private nonisolated struct Redirect: Decodable {
        let name: String
        let aliases: [String]?
        let contentType: String
        let body: String
    }

    private nonisolated struct File: Decodable {
        let scriptlets: [Scriptlet]
        let redirects: [Redirect]
    }

    /// Assembled code per scriptlet name and alias, `{{n}}` placeholders open.
    private let assembled: [String: String]
    /// JavaScript surrogate bodies by resource name and alias.
    private let surrogates: [String: String]
    let scriptletCount: Int

    init(data: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        var byName: [String: Scriptlet] = [:]
        for scriptlet in file.scriptlets {
            for name in [scriptlet.name] + (scriptlet.aliases ?? []) { byName[name] = scriptlet }
        }
        var assembled: [String: String] = [:]
        for scriptlet in file.scriptlets {
            let code = Self.assemble(scriptlet, byName: byName)
            for name in [scriptlet.name] + (scriptlet.aliases ?? []) { assembled[name] = code }
        }
        var surrogates: [String: String] = [:]
        for redirect in file.redirects where redirect.contentType == "application/javascript" {
            for name in [redirect.name] + (redirect.aliases ?? []) { surrogates[name] = redirect.body }
        }
        self.assembled = assembled
        self.surrogates = surrogates
        self.scriptletCount = file.scriptlets.count
    }

    /// Ghostery `assembleScript`: a shared `scriptletGlobals`, the
    /// dependency bodies, then the scriptlet called with up to ten
    /// URI-decoded args.
    private static func assemble(_ scriptlet: Scriptlet, byName: [String: Scriptlet]) -> String {
        // `getScriptletDependencies`: depth-first via pop(), first visit wins.
        var seen = Set<String>()
        var bodies: [String] = []
        var queue = scriptlet.dependencies ?? []
        while let name = queue.popLast() {
            guard seen.insert(name).inserted, let dependency = byName[name] else { continue }
            bodies.append(dependency.body)
            queue.append(contentsOf: dependency.dependencies ?? [])
        }
        let call = "(\(scriptlet.body))(...[`{{1}}`,`{{2}}`,`{{3}}`,`{{4}}`,`{{5}}`,`{{6}}`,`{{7}}`,`{{8}}`,`{{9}}`,`{{10}}`]"
            + ".filter((a,i) => a !== '{{'+(i+1)+'}}').map((a) => decodeURIComponent(a)))"
        return (["if (typeof scriptletGlobals === 'undefined') { var scriptletGlobals = {}; }"] + bodies + [call])
            .joined(separator: ";")
    }

    /// Ghostery `Resources.getScriptlet`: a scriptlet by name (`.js` implied),
    /// else a JavaScript surrogate of that name; `.fn` names are helpers only.
    private func code(for name: String) -> String? {
        let key = name.hasSuffix(".js") ? name : name + ".js"
        if !name.hasSuffix(".fn"), let code = assembled[key] { return code }
        return surrogates[key]
    }

    /// Ghostery `CosmeticFilter.getScript`: each arg regex-escaped (so it
    /// survives the template literal) and substituted for the first `{{n}}`
    /// with JavaScript `String.prototype.replace` semantics.
    func script(name: String, args: [String]) -> String? {
        guard var script = code(for: name) else { return nil }
        for (i, arg) in args.enumerated() {
            script = Self.replaceFirst("{{\(i + 1)}}", in: script, with: Self.escapeRegexCharacters(arg))
        }
        return script
    }

    /// `arg.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')`.
    static func escapeRegexCharacters(_ arg: String) -> String {
        // Unicode scalars, not Characters: JavaScript sees `.` + a combining
        // mark as two code units and escapes the dot.
        var out = String.UnicodeScalarView()
        for scalar in arg.unicodeScalars {
            if regexSpecials.contains(scalar) { out.append("\\") }
            out.append(scalar)
        }
        return String(out)
    }

    private static let regexSpecials = Set(".*+?^${}()|[]\\".unicodeScalars)

    /// `subject.replace(pattern, replacement)` for a string pattern: first
    /// occurrence only, `$$` `$&` `` $` `` `$'` expanded, any other `$`
    /// sequence literal (a string pattern has no capture groups).
    static func replaceFirst(_ pattern: String, in subject: String, with replacement: String) -> String {
        guard let range = subject.range(of: pattern, options: .literal) else { return subject }
        var expanded = String.UnicodeScalarView()
        var scalars = replacement.unicodeScalars[...]
        while let scalar = scalars.first {
            scalars = scalars.dropFirst()
            guard scalar == "$", let next = scalars.first else {
                expanded.append(scalar)
                continue
            }
            switch next {
            case "$": expanded.append("$"); scalars = scalars.dropFirst()
            case "&": expanded.append(contentsOf: subject[range].unicodeScalars); scalars = scalars.dropFirst()
            case "`": expanded.append(contentsOf: subject[..<range.lowerBound].unicodeScalars); scalars = scalars.dropFirst()
            case "'": expanded.append(contentsOf: subject[range.upperBound...].unicodeScalars); scalars = scalars.dropFirst()
            default: expanded.append("$")
            }
        }
        return subject.replacingCharacters(in: range, with: String(expanded))
    }
}
