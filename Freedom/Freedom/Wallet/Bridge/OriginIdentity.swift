import Foundation

/// Byte-identical to desktop's `getPermissionKey` in
/// `src/shared/origin-utils.js` — same mnemonic → same permission keys
/// across iOS and desktop.
struct OriginIdentity: Equatable, Hashable, Sendable {
    enum Scheme: String, Sendable {
        case ens, bzz, ipfs, ipns, rad, https, http, other
    }

    let key: String
    let scheme: Scheme

    /// Which origins reach `RPCRouter` (§6.5). Dweb cousins (ipfs/ipns/rad)
    /// and plaintext http are refused for parity with desktop.
    var isEligibleForWallet: Bool {
        switch scheme {
        case .https, .ens, .bzz: return true
        case .http, .ipfs, .ipns, .rad, .other: return false
        }
    }

    /// ENS keys are stored bare but users expect to see `ens://foo.eth` in
    /// approval sheets — reassemble the scheme for UI rendering only.
    var displayString: String {
        scheme == .ens ? "ens://\(key)" : key
    }

    /// Human label for approval-sheet scheme subtitles.
    var schemeDisplayLabel: String {
        switch scheme {
        case .ens: return "via Swarm (ENS name)"
        case .bzz: return "Swarm content-address"
        case .https: return "Web over HTTPS"
        case .http: return "Web over HTTP"
        case .ipfs: return "IPFS content-address"
        case .ipns: return "IPNS name"
        case .rad: return "Radicle"
        case .other: return "Unknown origin"
        }
    }

    static func from(displayURL: URL?) -> OriginIdentity? {
        guard let url = displayURL else { return nil }
        return from(string: url.absoluteString)
    }

    static func from(string raw: String) -> OriginIdentity? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Desktop's regex `^[a-z0-9-]+\.(eth|box)` is unanchored at end, so
        // `foo.ethereum.com` matches as ENS. Parity means we keep the quirk.
        if trimmed.range(
            of: #"^[a-z0-9-]+\.(eth|box)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            let host = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmed
            return .init(key: host.lowercased(), scheme: .ens)
        }

        let ensPrefix = "ens://"
        if trimmed.lowercased().hasPrefix(ensPrefix) {
            let tail = trimmed.dropFirst(ensPrefix.count)
            let name = tail.prefix(while: { $0 != "/" && $0 != "#" })
            guard !name.isEmpty else { return nil }
            return .init(key: name.lowercased(), scheme: .ens)
        }

        // Dweb schemes preserve ref case (multi-base hashes are case-sensitive).
        let dwebSchemes: [(String, Scheme)] = [
            ("bzz", .bzz), ("ipfs", .ipfs), ("ipns", .ipns), ("rad", .rad),
        ]
        for (name, enumCase) in dwebSchemes {
            let prefix = "\(name)://"
            if trimmed.lowercased().hasPrefix(prefix) {
                let tail = trimmed.dropFirst(prefix.count)
                let ref = tail.prefix(while: { $0 != "/" })
                guard !ref.isEmpty else { return nil }
                return .init(key: "\(name)://\(ref)", scheme: enumCase)
            }
        }

        // JS `URL.origin` strips default ports 80/443; Swift URL doesn't.
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           let host = url.host?.lowercased(),
           !host.isEmpty {
            var origin = "\(scheme)://\(host)"
            if let port = url.port,
               !(scheme == "https" && port == 443),
               !(scheme == "http" && port == 80) {
                origin += ":\(port)"
            }
            let enumCase: Scheme
            switch scheme {
            case "https": enumCase = .https
            case "http": enumCase = .http
            default: enumCase = .other
            }
            return .init(key: origin, scheme: enumCase)
        }

        return .init(key: trimmed, scheme: .other)
    }
}
