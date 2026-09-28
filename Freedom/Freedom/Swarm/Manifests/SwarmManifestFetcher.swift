import Foundation
import OSLog

private let log = Logger(subsystem: "com.browser.Freedom", category: "SwarmManifest")

/// Fetches `bzz://<host>/freedom-manifest.json` for a committed `bzz://`
/// page through the same resolution the page itself used: an ENS host
/// goes through `ENSResolver.resolveContent`, a bare reference straight
/// to the local bee gateway. Desktop's `discover()` over
/// `handleBzzRequest`.
@MainActor
struct SwarmManifestFetcher {
    /// Inactivity deadline for the response (desktop
    /// `BODY_IDLE_TIMEOUT_MS`): a gateway that answers headers and then
    /// stalls is a transport failure, not a bad manifest.
    static let idleTimeout: TimeInterval = 15

    private let ensResolver: any ENSResolving
    private let session: URLSession

    init(ensResolver: any ENSResolving, session: URLSession = .shared) {
        self.ensResolver = ensResolver
        self.session = session
    }

    func discover(committedURL: URL) async -> SwarmManifestDiscovery {
        guard committedURL.scheme?.lowercased() == "bzz", let host = committedURL.host, !host.isEmpty,
              let manifestURL = URL(string: "bzz://\(host)/\(SwarmManifest.fileName)") else {
            return .unsupported
        }

        var contentRef: String?
        if let name = committedURL.ensName {
            do {
                let resolved = try await ensResolver.resolveContent(name)
                guard resolved.codec == .bzz else { return .unresolved }
                contentRef = resolved.contentRef
            } catch {
                log.info("manifest for \(name, privacy: .public): ENS resolution failed — \(error)")
                return .unresolved
            }
        }
        guard let upstream = BzzSchemeHandler.localHTTPURL(for: manifestURL, resolvedTo: contentRef) else {
            return .unsupported
        }

        var request = URLRequest(url: upstream)
        // `timeoutInterval` is an inactivity timeout in Foundation: it
        // resets on every byte, so a slow-but-steady body keeps going.
        request.timeoutInterval = Self.idleTimeout
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .unresolved }
            if let verdict = Self.classify(status: http.statusCode) { return verdict }
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > SwarmManifest.maxBytes {
                    log.info("manifest at \(host, privacy: .public) exceeds \(SwarmManifest.maxBytes) bytes")
                    return .invalid
                }
            }
            return Self.accept(body: body, host: host)
        } catch {
            log.info("manifest for \(host, privacy: .public): fetch failed — \(error)")
            return .unresolved
        }
    }

    /// Desktop's status mapping: 404 → absent, other 4xx → invalid,
    /// 5xx → unresolved; `nil` means "read the body".
    static func classify(status: Int) -> SwarmManifestDiscovery? {
        switch status {
        case 200...299: nil
        case 404: .absent
        case 400...499: .invalid
        default: .unresolved
        }
    }

    static func accept(body: Data, host: String) -> SwarmManifestDiscovery {
        do {
            let manifest = try SwarmManifest.validate(body)
            return .found(manifest: manifest, rawHash: SwarmManifest.sha256Hex(body))
        } catch {
            log.info("manifest at \(host, privacy: .public) rejected: \(String(describing: error), privacy: .public)")
            return .invalid
        }
    }
}
