import Foundation

extension URL {
    /// User-presentable origin label. Host if available (the common case
    /// for http/https/bzz with authority), absolute string otherwise.
    var hostOrAbsolute: String {
        host ?? absoluteString
    }

    /// Lowercased Ethereum name if the URL's host is one, nil otherwise.
    /// Used by the scheme handlers + favicon store + BrowserTab.reload to
    /// detect name-origin URLs and bind the name in one step. Lowercases
    /// internally because custom schemes (bzz/ipfs/ipns) preserve host
    /// case where standard schemes (http/https) normalize it.
    ///
    /// Two tiers, per the ENSv2 readiness guide and desktop PR #352:
    ///  - a resolvable suffix (`.eth` ENS, `.wei` WNS, `.gwei` GNS) is a
    ///    name under any scheme — no DNS equivalent exists;
    ///  - any other dot-separated host (a DNS-imported ENS name such as
    ///    `gregskril.com`) is a name only where the user asked for name
    ///    resolution: `ens://`, or a content scheme (`bzz://`, `ipfs://`)
    ///    whose host can't otherwise be a content reference. `ipns://`
    ///    keeps DNSLink semantics and `http(s)://` keeps DNS, so a bare
    ///    DNS name in the address bar still opens over HTTPS.
    var ensName: String? {
        guard let lowered = host(percentEncoded: false)?.lowercased(), !lowered.isEmpty else { return nil }
        if NameSystem.navigableSuffixes.contains(where: lowered.hasSuffix) { return lowered }
        switch scheme?.lowercased() {
        case "ens":
            return NameSystem.isPotentialEnsName(lowered) ? lowered : nil
        case "bzz", "ipfs":
            guard NameSystem.isPotentialEnsName(lowered),
                  port == nil,
                  !NameSystem.isKnownIpfsGatewayHost(lowered),
                  !Self.isIPLiteral(lowered) else { return nil }
            return lowered
        default:
            return nil
        }
    }

    private static func isIPLiteral(_ host: String) -> Bool {
        if host.hasPrefix("[") || host.contains(":") { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count == 4 && labels.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
