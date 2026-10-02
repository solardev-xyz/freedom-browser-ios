import Foundation
import os

/// Where the Swarm (bee-compatible) HTTP API lives: the embedded
/// gateway on loopback, or an external node the user configured under
/// Settings → Swarm (desktop "explicit external nodes"). Every HTTP
/// user — `BeeAPIClient`, the `bzz:` scheme handler, the PSS socket —
/// reads `baseURL` here; `SettingsStore` writes it. Lock-protected so
/// the scheme handler and detached fetches can read it from anywhere.
final class SwarmGateway: Sendable {
    static let shared = SwarmGateway()
    static let embeddedURL = URL(string: "http://127.0.0.1:1633")!

    private let external = OSAllocatedUnfairLock<URL?>(initialState: nil)

    var externalURL: URL? { external.withLock { $0 } }
    var isExternal: Bool { externalURL != nil }
    var baseURL: URL { externalURL ?? Self.embeddedURL }

    func setExternal(_ url: URL?) { external.withLock { $0 = url } }

    /// `ws(s)://` twin of `baseURL`, for `/pss/subscribe`.
    var webSocketBase: URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return baseURL }
        components.scheme = components.scheme?.lowercased() == "https" ? "wss" : "ws"
        return components.url ?? baseURL
    }

    /// `baseURL` with an API path appended (the base may carry a path
    /// prefix of its own) and an optional raw query.
    func url(path: String, query: String? = nil) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + (path.hasPrefix("/") ? path : "/" + path)
        components.query = query
        return components.url
    }

    enum EndpointError: Error, Equatable {
        case empty
        case invalid
        /// Cleartext to a host outside the local network.
        case insecurePublicHost

        var message: String {
            switch self {
            case .empty: "Enter the node's API address."
            case .invalid: "Enter an address like https://bee.example.com or http://192.168.1.20:1633."
            case .insecurePublicHost: "A node outside your local network needs https://."
            }
        }
    }

    /// A typed endpoint: `http(s)://host[:port][/path]` and nothing
    /// else. Cleartext is accepted for loopback, private-network and
    /// `.local` hosts only — a public node must sit behind TLS (iOS's
    /// App Transport Security refuses it anyway).
    static func parseExternal(_ text: String) -> Result<URL, EndpointError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil, components.user == nil
        else { return .failure(.invalid) }
        if scheme == "http", !isLocalHost(host) { return .failure(.insecurePublicHost) }
        components.scheme = scheme
        components.host = host.lowercased()
        if components.path.hasSuffix("/") { components.path = String(components.path.dropLast()) }
        guard let url = components.url else { return .failure(.invalid) }
        return .success(url)
    }

    /// Loopback, RFC 1918, link-local, unique-local IPv6, `.local`.
    static func isLocalHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h.hasSuffix(".local") || h == "::1" { return true }
        if h.contains(":") { return h.hasPrefix("fe80:") || h.hasPrefix("fd") || h.hasPrefix("fc") }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ $0.map { (0...255).contains($0) } ?? false }) else { return false }
        let p = parts.map { $0! }
        if p[0] == 127 || p[0] == 10 { return true }
        if p[0] == 192, p[1] == 168 { return true }
        if p[0] == 172, (16...31).contains(p[1]) { return true }
        if p[0] == 169, p[1] == 254 { return true }
        return false
    }

    /// Probe an endpoint's `/health` without changing the setting.
    static func probe(_ url: URL) async -> Result<String, Error> {
        do {
            let (data, response) = try await URLSession.shared.data(from: url.appendingPathComponent("health"))
            guard let http = response as? HTTPURLResponse else { return .failure(URLError(.badServerResponse)) }
            guard http.statusCode == 200 else { return .failure(URLError(.badServerResponse)) }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let status = json?["status"] as? String ?? "?"
            let version = json?["version"] as? String ?? "unknown version"
            return .success("\(status) · bee API \(version)")
        } catch {
            return .failure(error)
        }
    }
}
