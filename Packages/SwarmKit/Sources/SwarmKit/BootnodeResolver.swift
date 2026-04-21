import Foundation

public enum BootnodeResolver {
    private static let doHEndpoint = URL(string: "https://cloudflare-dns.com/dns-query")!
    private static let maxDepth = 4
    private static let totalTimeout: TimeInterval = 3.0
    private static let perQueryTimeout: TimeInterval = 2.0

    /// Resolve fresh Swarm mainnet bootnode multiaddrs by walking the
    /// `/dnsaddr/` DNS-TXT chain via DNS-over-HTTPS (Cloudflare).
    /// Returns a flat list of leaf IP-literal multiaddrs, or `[]` on any
    /// failure (timeout, network error, malformed response, empty chain).
    /// Callers should fall back to their own hardcoded list on `[]`.
    public static func resolveMainnet() async -> [String] {
        await resolve(rootDomain: "mainnet.ethswarm.org")
    }

    public static func resolve(rootDomain: String) async -> [String] {
        let deadline = Date().addingTimeInterval(totalTimeout)
        return await follow(multiaddr: "/dnsaddr/\(rootDomain)", depth: 0, deadline: deadline)
    }

    private static func follow(multiaddr: String, depth: Int, deadline: Date) async -> [String] {
        guard depth < maxDepth, Date() < deadline else { return [] }
        guard multiaddr.hasPrefix("/dnsaddr/") else {
            // Already a leaf (e.g. /ip4/.../tcp/.../p2p/...).
            return [multiaddr]
        }
        let host = String(multiaddr.dropFirst("/dnsaddr/".count))
        let records = await queryTXT(name: "_dnsaddr.\(host)", deadline: deadline)
        let nextMultiaddrs = records.compactMap { rec -> String? in
            guard rec.hasPrefix("dnsaddr=") else { return nil }
            return String(rec.dropFirst("dnsaddr=".count))
        }
        return await withTaskGroup(of: [String].self) { group in
            for next in nextMultiaddrs {
                group.addTask {
                    await follow(multiaddr: next, depth: depth + 1, deadline: deadline)
                }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }
    }

    private static func queryTXT(name: String, deadline: Date) async -> [String] {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return [] }
        var components = URLComponents(url: doHEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "type", value: "TXT"),
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: min(remaining, perQueryTimeout))
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["Status"] as? Int) == 0,
                  let answers = json["Answer"] as? [[String: Any]] else {
                return []
            }
            return answers.compactMap { ans in
                guard let raw = ans["data"] as? String else { return nil }
                // DoH JSON wraps TXT rdata in literal double-quotes — strip them.
                if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
                    return String(raw.dropFirst().dropLast())
                }
                return raw
            }
        } catch {
            return []
        }
    }
}
