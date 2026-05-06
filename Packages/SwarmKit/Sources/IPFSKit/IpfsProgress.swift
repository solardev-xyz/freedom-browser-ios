import Foundation

/// Decoded form of `freedom_ipfs_node_progress_snapshot_json`. The
/// schema is documented in `freedom-ipfs/docs/mobile-progress-api.md`.
///
/// Resilience policy (per the Rust agent's handoff): every field
/// except the top-level arrays is optional, so partial / older / newer
/// snapshots decode without breaking. Decoding is wrapped in `try?`
/// at the `IPFSNode` call site, so a malformed snapshot keeps the
/// previous value rather than crashing browsing.
public struct IpfsProgressSnapshot: Decodable, Sendable, Equatable {
    public let generatedAtUnixMs: UInt64?
    public let eventCount: Int?
    /// Targets currently in flight. Completed / failed / cancelled
    /// targets fall out of this array; their final state remains
    /// visible in `events`.
    public let active: [IpfsProgressTarget]
    /// Recent events, capped to the last 512 by the Rust gateway.
    public let events: [IpfsProgressEvent]

    public init(
        generatedAtUnixMs: UInt64? = nil,
        eventCount: Int? = nil,
        active: [IpfsProgressTarget] = [],
        events: [IpfsProgressEvent] = []
    ) {
        self.generatedAtUnixMs = generatedAtUnixMs
        self.eventCount = eventCount
        self.active = active
        self.events = events
    }

    /// Custom decoder so missing `active` / `events` arrays default
    /// to empty rather than throwing. The other fields are optional
    /// and would synthesize the same way; we explicitly use the
    /// keyed container so the array defaulting reads cleanly.
    private enum CodingKeys: String, CodingKey {
        case generatedAtUnixMs
        case eventCount
        case active
        case events
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAtUnixMs = try c.decodeIfPresent(UInt64.self, forKey: .generatedAtUnixMs)
        eventCount = try c.decodeIfPresent(Int.self, forKey: .eventCount)
        active = try c.decodeIfPresent([IpfsProgressTarget].self, forKey: .active) ?? []
        events = try c.decodeIfPresent([IpfsProgressEvent].self, forKey: .events) ?? []
    }

    /// Sentinel used when no snapshot has been polled yet.
    public static let empty = IpfsProgressSnapshot()

    /// Reusable decoder configured for the snake_case JSON the Rust
    /// gateway emits. Hot-path-allocating a `JSONDecoder` for every
    /// poll tick is wasteful — the loop reuses this instance.
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

/// One in-flight gateway request. Subresources of a top-level
/// navigation share the same `topLevelPath` and have their parent's
/// id in `parentId`.
public struct IpfsProgressTarget: Decodable, Sendable, Equatable, Identifiable {
    public let id: UInt64
    public let requestId: UInt64?
    public let parentId: UInt64?
    public let kind: String?
    public let path: String?
    public let topLevelPath: String?
    public let namespace: String?
    public let phase: String?
    public let status: String?
    public let source: String?
    public let transport: String?
    public let delivery: String?
    public let bytesLoaded: UInt64?
    public let bytesTotal: UInt64?
    public let activeSubrequests: Int?
    public let elapsedMs: UInt64?
    public let blocksLoaded: UInt64?
    public let retryCount: Int?
    public let lastErrorCode: String?
    public let lastErrorMessage: String?
    public let lastEventId: UInt64?
    public let updatedMs: UInt64?
}

/// One progress event in the bounded event log. Events for completed,
/// failed, or cancelled targets remain here even after the target
/// drops out of the snapshot's `active` array.
public struct IpfsProgressEvent: Decodable, Sendable, Equatable, Identifiable {
    public var id: UInt64 { eventId }
    public let eventId: UInt64
    public let targetId: UInt64?
    public let requestId: UInt64?
    public let parentId: UInt64?
    public let kind: String?
    public let path: String?
    public let topLevelPath: String?
    public let namespace: String?
    public let phase: String?
    /// Lower-level Rust diagnostic phase. Kept for logs / debugging.
    /// Use `phase` for UI state.
    public let rawPhase: String?
    public let status: String?
    public let source: String?
    public let transport: String?
    public let delivery: String?
    public let bytesLoaded: UInt64?
    public let bytesTotal: UInt64?
    public let providersFound: Int?
    public let candidatePeers: Int?
    public let blocksLoaded: UInt64?
    public let retryCount: Int?
    public let elapsedMs: UInt64?
    public let lastErrorCode: String?
    public let lastErrorMessage: String?
    public let timestampMs: UInt64?
}

/// Phase-string → user-facing copy. The mapping is taken verbatim
/// from `freedom-ipfs/docs/mobile-progress-api.md` so the iOS UI
/// stays aligned with what the Rust gateway considers stable
/// UI-facing phases. Returns `nil` for terminal states the UI
/// shouldn't surface (`completed`, `cancelled`) or for unknown
/// phases — callers should fall back to a neutral "Loading…" string
/// in those cases.
public enum IpfsProgressPhaseDisplay {
    public static func text(for phase: String?) -> String? {
        guard let phase else { return nil }
        switch phase {
        case "queued": return "Waiting for gateway capacity"
        case "started": return "Loading"
        case "resolving_name": return "Resolving IPNS name"
        case "name_resolved": return "Name resolved"
        case "checking_cache", "cache_hit": return "Checking local cache"
        case "provider_lookup",
             "providers_found",
             "provider_diversity_low":
            return "Finding providers"
        case "dht_fallback_started": return "Searching the network"
        case "fetching_bitswap": return "Fetching from IPFS peers"
        case "fetching_http_provider": return "Fetching from HTTP provider"
        case "streaming": return "Receiving content"
        case "retrying": return "Retrying slow provider"
        case "failed": return "Load failed"
        case "completed", "cancelled":
            return nil
        default:
            return nil
        }
    }
}

public extension IpfsProgressTarget {
    /// User-facing description for the current `phase` string.
    var displayPhase: String? {
        IpfsProgressPhaseDisplay.text(for: phase)
    }
}

public extension IpfsProgressEvent {
    var displayPhase: String? {
        IpfsProgressPhaseDisplay.text(for: phase)
    }
}
