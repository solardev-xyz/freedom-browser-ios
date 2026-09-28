import CryptoKit
import Foundation

/// A capability a bzz-hosted app can declare in its permission manifest
/// (`bzz://<host>/freedom-manifest.json`). Same four keys, labels and
/// details as desktop's `CAPABILITY_KEYS` / `CAPABILITY_META` so a
/// manifest reads identically on both platforms.
enum SwarmManifestCapability: String, CaseIterable, Codable, Sendable {
    case publish
    case feeds
    case signing
    case messaging

    var label: String {
        switch self {
        case .publish: "Publish content"
        case .feeds: "Manage feeds"
        case .signing: "Sign Swarm content"
        case .messaging: "Send and receive messages"
        }
    }

    var detail: String {
        switch self {
        case .publish: "Use your postage stamps and bandwidth."
        case .feeds: "Create and update app feeds without repeated approval."
        case .signing: "Use an app-scoped publisher identity."
        case .messaging: "Use PSS and GSOC messaging."
        }
    }

    /// What "Allow all" turns on for this capability, in application
    /// order (connection first — the auto-approve flags and the
    /// messaging grant live on the connection row). Desktop's
    /// `PROJECTIONS`, minus its separate feed-grant flag: on iOS the
    /// feed grant *is* the `SwarmFeedIdentity` row, and feeds and
    /// signing share one auto-approve flag (one feed/signing tier).
    var projections: [SwarmManifestProjection] {
        switch self {
        case .publish: [.connection, .autoApprovePublish]
        case .feeds, .signing: [.connection, .identity, .autoApproveFeeds]
        case .messaging: [.connection, .messagingGrant, .autoApproveMessaging]
        }
    }
}

/// One piece of per-origin state a manifest capability projects onto.
/// Raw values match desktop's projection keys so the persisted grants
/// file reads the same.
enum SwarmManifestProjection: String, CaseIterable, Codable, Sendable {
    case connection
    case identity
    case messagingGrant
    case autoApprovePublish = "autoApprove.publish"
    case autoApproveFeeds = "autoApprove.feeds"
    case autoApproveMessaging = "autoApprove.messaging"
}

/// A validated manifest — only the fields the sheet and the store use.
struct SwarmManifest: Equatable, Sendable {
    static let schema = "freedom-manifest/1"
    /// Desktop `MAX_BYTES`: a manifest body larger than this is invalid.
    static let maxBytes = 8 * 1024
    static let fileName = "freedom-manifest.json"

    let schema: String
    let name: String
    let description: String
    /// Declared capabilities with the app's reason for each.
    let capabilities: [SwarmManifestCapability: String]

    var declared: [SwarmManifestCapability] {
        SwarmManifestCapability.allCases.filter { capabilities[$0] != nil }
    }

    /// Hash of what the consent is *about* (schema + capability set), so
    /// a wording-only redeploy doesn't invalidate an outstanding token.
    /// Same bytes as desktop's `fingerprint()` (`JSON.stringify` of
    /// `{schema, capabilities: sortedKeys}`).
    var fingerprint: String {
        let keys = capabilities.keys.map(\.rawValue).sorted().map { "\"\($0)\"" }.joined(separator: ",")
        let json = "{\"schema\":\"\(schema)\",\"capabilities\":[\(keys)]}"
        return Self.sha256Hex(Data(json.utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    enum ValidationError: Swift.Error, Equatable {
        case notAnObject(String)
        case unknownField(String, String)
        case unsupportedSchema
        case invalidName
        case invalidDescription
        case emptyCapabilities
        case invalidReason(String)
        case notJSON
    }

    /// Desktop's `validateManifest`: exact key sets at every level, a
    /// supported schema, and display text that is short and free of
    /// control / bidi characters (it is rendered verbatim on the sheet).
    static func validate(_ data: Data) throws -> SwarmManifest {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw ValidationError.notJSON
        }
        let root = try exactKeys(object, allowed: ["schema", "name", "description", "capabilities"], label: "manifest")
        guard root["schema"] as? String == schema else { throw ValidationError.unsupportedSchema }
        guard let name = root["name"] as? String, !hasUnsafeText(name, maxLength: 32),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.invalidName
        }
        var description = ""
        if let raw = root["description"] {
            guard let text = raw as? String, !hasUnsafeText(text, maxLength: 160) else {
                throw ValidationError.invalidDescription
            }
            description = text
        }
        let capabilities = try exactKeys(root["capabilities"], allowed: ["swarm"], label: "capabilities")
        let swarm = try exactKeys(
            capabilities["swarm"],
            allowed: SwarmManifestCapability.allCases.map(\.rawValue),
            label: "capabilities.swarm"
        )
        guard !swarm.isEmpty else { throw ValidationError.emptyCapabilities }

        var declared: [SwarmManifestCapability: String] = [:]
        for capability in SwarmManifestCapability.allCases {
            guard let raw = swarm[capability.rawValue] else { continue }
            let row = try exactKeys(raw, allowed: ["why"], label: "capability \(capability.rawValue)")
            guard let why = row["why"] as? String, !hasUnsafeText(why, maxLength: 140),
                  !why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError.invalidReason(capability.rawValue)
            }
            declared[capability] = why
        }
        return SwarmManifest(schema: schema, name: name, description: description, capabilities: declared)
    }

    private static func exactKeys(_ value: Any?, allowed: [String], label: String) throws -> [String: Any] {
        guard let dict = value as? [String: Any] else { throw ValidationError.notAnObject(label) }
        for key in dict.keys where !allowed.contains(key) {
            throw ValidationError.unknownField(label, key)
        }
        return dict
    }

    /// Desktop's `hasUnsafeText`: length counted in code points; C0/C1
    /// controls, bidi overrides / isolates and the line separators are
    /// rejected.
    static func hasUnsafeText(_ value: String, maxLength: Int) -> Bool {
        let scalars = value.unicodeScalars
        guard scalars.count <= maxLength else { return true }
        return scalars.contains { scalar in
            let v = scalar.value
            return v <= 0x1f
                || (0x7f...0x9f).contains(v)
                || (0x202a...0x202e).contains(v)
                || v == 0x2028 || v == 0x2029
                || (0x2066...0x2069).contains(v)
        }
    }
}

/// Outcome of looking for an origin's manifest. Only bytes we actually
/// hold and cannot accept are `invalid` (that prunes manifest-managed
/// authority); anything transport-shaped is `unresolved` and backs off.
enum SwarmManifestDiscovery: Equatable, Sendable {
    /// Not a `bzz://` origin — manifests are only hosted on Swarm.
    case unsupported
    /// Bee answered 404: the app has no manifest.
    case absent
    /// Oversized, non-JSON, schema-violating, or a 4xx other than 404.
    case invalid
    /// Transport failure, 5xx, or a body that died mid-stream.
    case unresolved
    case found(manifest: SwarmManifest, rawHash: String)
}
