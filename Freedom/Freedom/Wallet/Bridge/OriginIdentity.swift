import Foundation

/// Byte-identical to desktop's `getPermissionKey` in
/// `src/shared/origin-utils.js` — same mnemonic → same permission keys
/// across iOS and desktop.
struct OriginIdentity: Equatable, Hashable, Sendable {
    enum Scheme: String, Sendable {
        case ens, bzz, ipfs, ipns, rad, https, http, other
        /// A remote browser connected over an openlv session (QR scan /
        /// pasted link). Constructed directly by `OpenLVWalletSession`
        /// for its approval sheets — never parsed from a tab URL and
        /// never persisted to a permission store.
        case openlv
    }

    let key: String
    let scheme: Scheme

    /// Which origins reach `RPCRouter` (§6.5). Dweb cousins (ipfs/ipns/rad)
    /// and plaintext http are refused for parity with desktop. ENS-named
    /// hosts never carry these schemes: `from(string:)` carves
    /// `ipfs://name.eth` out to `.ens` before scheme classification, same
    /// as desktop's name-host carve-out.
    var isEligibleForWallet: Bool {
        switch scheme {
        case .https, .ens, .bzz: return true
        // .openlv never arrives via a tab — its requests bypass the
        // dapp bridge entirely, so tab-side eligibility stays false.
        case .http, .ipfs, .ipns, .rad, .other, .openlv: return false
        }
    }

    /// ENS keys are stored bare but users expect to see `ens://foo.eth` in
    /// approval sheets — reassemble the scheme for UI rendering only.
    var displayString: String {
        switch scheme {
        case .ens: return "ens://\(key)"
        case .openlv: return "Connected browser"
        default: return key
        }
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
        case .openlv: return "Remote signing session (OpenLV)"
        }
    }

    static func from(displayURL: URL?) -> OriginIdentity? {
        guard let url = displayURL else { return nil }
        return from(string: url.absoluteString)
    }

    /// Desktop's `isEnsHost` — the single predicate for supported name
    /// suffixes on both platforms. Delegates to `NameSystem` so the
    /// suffix set can't drift between permission keying and resolution.
    static func isEnsHost<S: StringProtocol>(_ host: S) -> Bool {
        NameSystem.isSupportedName(host)
    }

    static func from(string raw: String) -> OriginIdentity? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Desktop's regex `^[a-z0-9-]+\.(eth|box|wei|gwei)` is unanchored at
        // end, so `foo.ethereum.com` matches as ENS. Parity means we keep the
        // quirk. Splitting on /, ?, AND # collapses hash-routed SPAs
        // (`name.eth#/swap`) and share-link queries to the canonical bare name.
        if trimmed.range(
            of: #"^[a-z0-9-]+\.(eth|box|wei|gwei)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            let host = trimmed.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" })
            return .init(key: host.lowercased(), scheme: .ens)
        }

        let ensPrefix = "ens://"
        if trimmed.lowercased().hasPrefix(ensPrefix) {
            let tail = trimmed.dropFirst(ensPrefix.count)
            let name = tail.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" })
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
                let ref = tail.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" })
                guard !ref.isEmpty else { return nil }
                // Name-host carve-out (desktop origin-utils.js): an ENS site
                // served over a transport scheme keeps its bare name as the
                // permission key — `ipfs://myapp.eth/docs` → `myapp.eth` —
                // so grants don't fork between the `ens://` and transport
                // displays of the same site, and wallet eligibility follows
                // the name, not the transport. rad:// is excluded, matching
                // desktop's separate no-carve-out rad branch.
                if enumCase != .rad, isEnsHost(ref) {
                    return .init(key: ref.lowercased(), scheme: .ens)
                }
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
