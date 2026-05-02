import Foundation

/// JSON read-modify-write of kubo's `<dataDir>/config` file. Used by the
/// identity injector to swap the `Identity` section without touching
/// any other field (gateway port, routing mode, datastore paths,
/// addresses, etc).
///
/// Mirrors desktop Freedom's `identity/injection.js:injectIpfsKey`
/// approach — read JSON, set `Identity.PrivKey` + `Identity.PeerID`,
/// write back.
enum IpfsKuboConfig {
    enum Error: Swift.Error, LocalizedError {
        case configNotFound(URL)
        case invalidConfig(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .configNotFound(let url):
                "kubo config not found at \(url.path)"
            case .invalidConfig(let detail):
                "kubo config is malformed: \(detail)"
            case .writeFailed(let detail):
                "couldn't write kubo config: \(detail)"
            }
        }
    }

    /// Path of the JSON config file kubo's `fsrepo.Open` expects. No
    /// extension by kubo convention.
    static func configPath(for dataDir: URL) -> URL {
        dataDir.appendingPathComponent("config")
    }

    /// Read the current PeerID from kubo's config. Returns nil if the
    /// config file is missing entirely (typical for a freshly-installed
    /// app where the IPFS node hasn't booted yet) or the Identity
    /// section is absent. A malformed config throws.
    static func currentPeerID(at dataDir: URL) throws -> String? {
        let url = configPath(for: dataDir)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.invalidConfig("top-level JSON is not an object")
        }
        return (json["Identity"] as? [String: Any])?["PeerID"] as? String
    }

    /// Update `Identity.PeerID` and `Identity.PrivKey` while preserving
    /// every other top-level field. Throws `configNotFound` if kubo
    /// hasn't initialised the repo yet — caller is responsible for
    /// ensuring the node has booted at least once first (which runs
    /// `fsrepo.Init` and writes the default config).
    static func injectIdentity(
        at dataDir: URL,
        peerID: String,
        privKeyBase64: String
    ) throws {
        let url = configPath(for: dataDir)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.configNotFound(url)
        }
        let data = try Data(contentsOf: url)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.invalidConfig("top-level JSON is not an object")
        }
        var identity = (json["Identity"] as? [String: Any]) ?? [:]
        identity["PeerID"] = peerID
        identity["PrivKey"] = privKeyBase64
        json["Identity"] = identity
        let updated = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        do {
            try updated.write(to: url, options: .atomic)
        } catch {
            throw Error.writeFailed(error.localizedDescription)
        }
    }
}
