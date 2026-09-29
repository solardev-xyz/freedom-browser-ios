import CryptoKit
import Foundation

/// Tezos Domains names, the registry's key hashing, and the website
/// record a name publishes — the pure parts of desktop's
/// `tezos-domains-resolver.js`.
enum TezosDomains {
    static let suffix = ".tez"

    /// Desktop `isTezosDomainName` / `isTezosDomainHost`: a `.tez` name
    /// with non-empty labels, no whitespace, path or control characters.
    static func isName(_ value: some StringProtocol) -> Bool {
        let lower = value.lowercased()
        guard lower.hasSuffix(suffix), lower.count <= 255 else { return false }
        for scalar in lower.unicodeScalars {
            let v = scalar.value
            if v <= 0x1f || v == 0x7f || " \t\n\r/?#".unicodeScalars.contains(scalar) { return false }
        }
        return lower.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty }
    }

    // MARK: - ScriptExpr hash

    private static let scriptExprPrefix = Data([13, 44, 64, 27])

    /// The big-map key hash Tezos RPC addresses records by: base58check
    /// of `expr` prefix + blake2b-256 of the Micheline-packed bytes
    /// (`0x05 0x0a` + big-endian length + bytes).
    static func scriptExprHash(_ keyBytes: Data) -> String {
        var packed = Data([0x05, 0x0a])
        let length = UInt32(keyBytes.count)
        packed.append(contentsOf: [UInt8(length >> 24), UInt8((length >> 16) & 0xff), UInt8((length >> 8) & 0xff), UInt8(length & 0xff)])
        packed.append(keyBytes)
        let digest = Blake2b.hash(packed, outputLength: 32)
        return base58Check(scriptExprPrefix + digest)
    }

    static func base58Check(_ payload: Data) -> String {
        let first = Data(SHA256.hash(data: payload))
        let checksum = Data(SHA256.hash(data: first)).prefix(4)
        return Base58.encode(payload + checksum)
    }

    // MARK: - Micheline

    /// `pair` nodes flattened to their leaves, in order.
    static func flattenPairLeaves(_ node: Any?) -> [Any] {
        if let dict = node as? [String: Any], (dict["prim"] as? String)?.lowercased() == "pair" {
            return (dict["args"] as? [Any] ?? []).flatMap { flattenPairLeaves($0) }
        }
        return node.map { [$0] } ?? []
    }

    /// The value leaf sitting under the type leaf annotated `annotation`
    /// (`%records`, `%data`, …).
    static func findAnnotatedValue(type: Any?, value: Any?, annotation: String) -> (type: [String: Any], value: Any)? {
        guard let type, let value else { return nil }
        let typeLeaves = flattenPairLeaves(type)
        let valueLeaves = flattenPairLeaves(value)
        guard let index = typeLeaves.firstIndex(where: { leaf in
            ((leaf as? [String: Any])?["annots"] as? [String])?.contains(annotation) == true
        }), index < valueLeaves.count, let typeLeaf = typeLeaves[index] as? [String: Any] else { return nil }
        return (typeLeaf, valueLeaves[index])
    }

    static func storageType(fromScript script: Any?) -> Any? {
        guard let code = (script as? [String: Any])?["code"] as? [Any] else { return nil }
        let storage = code.first { ($0 as? [String: Any])?["prim"] as? String == "storage" } as? [String: Any]
        return (storage?["args"] as? [Any])?.first
    }

    static func bytes(fromHex value: Any?) -> Data? {
        guard let hex = value as? String, hex.count % 2 == 0, hex.allSatisfy(\.isHexDigit) else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    /// A `bytes` leaf holding UTF-8 JSON (how Tezos Domains stores record values).
    static func decodeJSONBytes(_ value: Any?) -> Any? {
        guard let data = bytes(fromHex: value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// `map string bytes` → key → hex value.
    static func mapEntries(_ value: Any?) -> [String: String] {
        var out: [String: String] = [:]
        for case let entry as [String: Any] in (value as? [Any] ?? []) where entry["prim"] as? String == "Elt" {
            guard let args = entry["args"] as? [Any], args.count == 2,
                  let key = (args[0] as? [String: Any])?["string"] as? String,
                  let hex = (args[1] as? [String: Any])?["bytes"] as? String else { continue }
            out[key] = hex
        }
        return out
    }

    // MARK: - Website records

    /// What a `.tez` name publishes for the browser: an HTTP(S) redirect
    /// or content URL, or IPFS / IPNS content served under the name.
    struct WebsiteRecord: Equatable {
        enum Kind: Equatable { case web, ipfs, ipns }
        let kind: Kind
        /// The published URI, normalized.
        let uri: URL
        /// The CID / IPNS key / DNSLink host for `.ipfs` / `.ipns`.
        let decoded: String?
        /// Path embedded in the published URI (no trailing slash), prepended to every request.
        let basePath: String
        /// True for `web:redirect_url`.
        let redirect: Bool
        var expiry: String? = nil
        var ttl: Int? = nil
    }

    enum RecordParse: Equatable {
        case ok(WebsiteRecord)
        case unsupported(reason: String)
    }

    /// Desktop `parsePublishedUri`. A record must point at content,
    /// never at another dweb name (`ipns://self.tez` would resolve
    /// forever); a redirect must be HTTP(S).
    static func parsePublishedURI(_ raw: String, redirect: Bool = false) -> RecordParse {
        guard raw.count <= 8_192, let components = URLComponents(string: raw), let scheme = components.scheme?.lowercased() else {
            return .unsupported(reason: "invalid website URI")
        }
        if redirect, scheme != "http", scheme != "https" {
            return .unsupported(reason: "redirect URL must use HTTP(S)")
        }
        if scheme == "http" || scheme == "https" {
            guard let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
                  let url = components.url else {
                return .unsupported(reason: "invalid HTTP(S) website URI")
            }
            return .ok(WebsiteRecord(kind: .web, uri: url, decoded: nil, basePath: "", redirect: redirect))
        }
        if !redirect, scheme == "ipfs" || scheme == "ipns" {
            guard let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
                  components.port == nil, let url = components.url else {
                return .unsupported(reason: "invalid \(scheme.uppercased()) website URI")
            }
            var nameCheck = host
            while nameCheck.hasSuffix(".") { nameCheck.removeLast() }
            nameCheck = nameCheck.removingPercentEncoding ?? nameCheck
            if NameSystem.isDwebName(nameCheck) {
                return .unsupported(reason: "\(scheme.uppercased()) website URI must reference content, not a name")
            }
            var basePath = components.path
            if basePath == "/" { basePath = "" }
            while basePath.hasSuffix("/") { basePath.removeLast() }
            return .ok(WebsiteRecord(kind: scheme == "ipfs" ? .ipfs : .ipns, uri: url, decoded: host, basePath: basePath, redirect: false))
        }
        return .unsupported(reason: "unsupported website protocol: \(scheme)")
    }
}
