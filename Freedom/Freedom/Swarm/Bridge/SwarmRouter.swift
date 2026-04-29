import Foundation

/// Non-interactive method dispatch for `window.swarm`. Mirrors
/// `RPCRouter`'s shape: pure compute over injected dependencies,
/// returns a JSON-shaped `Any` for the bridge to pipe back to the
/// page, throws `RouterError` on any failure (the bridge maps to a
/// JSON-RPC error envelope).
///
/// Interactive methods — `swarm_requestAccess`, and at WP5/WP6 the
/// publish/feed-write methods — bypass the router and run in
/// `SwarmBridge` so they can park an approval continuation. Refused
/// methods (publish/feed at WP4, all unknowns) return `4200`.
@MainActor
final class SwarmRouter {
    enum RouterError: Swift.Error, Equatable {
        case unsupportedMethod(method: String)
        case invalidParams(reason: String?, message: String)
        case nodeUnavailable(reason: String)
        case internalError(message: String)
    }

    /// Wire-format error envelope. `dataReason` populates JSON-RPC's
    /// `error.data.reason` for `4900` and `-32602` errors so dapps can
    /// branch on the structured reason without parsing `message`.
    struct ErrorPayload: Equatable {
        let code: Int
        let message: String
        let dataReason: String?

        /// EIP-1193-aligned codes. Same numbers as `RPCRouter.ErrorPayload.Code`
        /// where they overlap, so a dapp wiring a single error handler can
        /// dispatch on `code` regardless of which provider threw.
        enum Code {
            static let userRejected = 4001         // SWIP §"4001"
            static let unauthorized = 4100         // SWIP §"4100"
            static let unsupportedMethod = 4200    // SWIP §"4200"
            static let nodeUnavailable = 4900      // SWIP §"4900"
            /// EIP-1474; not in the SWIP table but the wallet bridge
            /// returns it for the same condition (concurrent-approval
            /// contention) so a dapp's single error handler can match
            /// across both providers.
            static let resourceUnavailable = -32002
            static let invalidParams = -32602      // JSON-RPC 2.0
            static let internalError = -32603      // JSON-RPC 2.0
        }

        /// Vocabulary for `error.data.reason` and
        /// `swarm_getCapabilities.result.reason`. Single source of truth so
        /// the JS-side feature-detect on a `not-connected` capabilities
        /// reply reads the same string a JS-side error handler would see
        /// from a publish-in-ultralight-mode 4900.
        enum Reason {
            // capability reasons (also used as 4900 data.reason on
            // permission-gated calls in WP5/WP6)
            static let notConnected = "not-connected"
            static let nodeStopped = "node-stopped"
            static let ultraLightMode = "ultra-light-mode"
            static let nodeNotReady = "node-not-ready"
            static let noUsableStamps = "no-usable-stamps"
            // -32602 reasons — full list per SWIP §"Structured Error Reasons"
            static let feedEmpty = "feed_empty"
            static let entryNotFound = "entry_not_found"
            static let feedNotFound = "feed_not_found"
            static let indexAlreadyExists = "index_already_exists"
            static let payloadTooLarge = "payload_too_large"
            static let invalidTopic = "invalid_topic"
            static let invalidOwner = "invalid_owner"
            static let invalidFeedName = "invalid_feed_name"
        }
    }

    /// Result shape passed back from the bee feed-read closure. Mirrors
    /// `BeeAPIClient.FeedReadResult` but kept router-local so the router
    /// has no transport dependency.
    struct FeedRead: Equatable {
        let payload: Data
        let index: UInt64
        let nextIndex: UInt64?
    }

    /// Sentinel errors the `readFeed` closure surfaces. The router
    /// translates them into SWIP wire reasons; transport / parse
    /// failures the closure can't classify propagate as `internalError`.
    enum FeedReadError: Swift.Error, Equatable {
        /// Bee returned 404 — `feed_empty` (no index) or `entry_not_found`
        /// (specific index) depending on the read shape.
        case notFound
        /// Bee's HTTP API isn't responding — `node-stopped`. Lets us skip
        /// a separate `/node` reachability probe (the actual `/feeds`
        /// call surfaces this directly) and dodges the probe-then-call
        /// race where state changes between the two.
        case unreachable
    }

    /// Hot-path connection check — `SwarmPermissionStore.isConnected` in
    /// production. Closure rather than a store reference so the router
    /// has read-only access to exactly what it needs (no `grant`/`revoke`
    /// surface) and tests can stub it without a SwiftData container.
    private let isConnected: @MainActor (String) -> Bool
    /// Caller-origin-scoped, already in `swarm_listFeeds` row shape.
    /// Production wiring maps `SwarmFeedStore.all(forOrigin:)` through
    /// `SwarmFeedRecord.asListFeedsRow`; tests inject pre-formed dicts
    /// directly so the router stays SwiftData-free.
    private let listFeedsForOrigin: @MainActor (String) -> [[String: Any]]
    /// Returns `nil` when bee is fully ready, or one of the node-side
    /// `Reason` strings otherwise. Production wiring composes from
    /// `SwarmNode.status`, `SettingsStore.beeNodeMode`,
    /// `BeeReadiness.state`, and `StampService.hasUsableStamps`.
    private let nodeFailureReason: @MainActor () -> String?
    /// Stored owner address for `(origin, name)`, from the local feed
    /// store. Returns `nil` when no record exists — `swarm_readFeedEntry`
    /// translates that to `feed_not_found`.
    private let feedOwner: @MainActor (String, String) -> String?
    /// `(owner, topic, index?)` → bee `GET /feeds/{owner}/{topic}`.
    /// Throws `FeedReadError.notFound` for bee 404,
    /// `FeedReadError.unreachable` when bee's HTTP API can't be reached,
    /// anything else for transport / parse failures.
    private let readFeed: @MainActor (String, String, UInt64?) async throws -> FeedRead

    init(
        isConnected: @escaping @MainActor (String) -> Bool,
        listFeedsForOrigin: @escaping @MainActor (String) -> [[String: Any]],
        nodeFailureReason: @escaping @MainActor () -> String?,
        feedOwner: @escaping @MainActor (String, String) -> String?,
        readFeed: @escaping @MainActor (String, String, UInt64?) async throws -> FeedRead
    ) {
        self.isConnected = isConnected
        self.listFeedsForOrigin = listFeedsForOrigin
        self.nodeFailureReason = nodeFailureReason
        self.feedOwner = feedOwner
        self.readFeed = readFeed
    }

    func handle(method: String, params: [String: Any], origin: OriginIdentity) async throws -> Any {
        switch method {
        case "swarm_getCapabilities":
            return capabilities(origin: origin).asJSONDict
        case "swarm_listFeeds":
            return listFeeds(origin: origin)
        case "swarm_readFeedEntry":
            return try await readFeedEntry(params: params, origin: origin)
        default:
            throw RouterError.unsupportedMethod(method: method)
        }
    }

    /// Surfaced for `SwarmBridge`'s pre-call gate on permission-required
    /// methods (WP5/WP6 publish + feed-write) — same vocabulary as
    /// `swarm_getCapabilities.reason` so dapps don't have to learn two.
    func capabilities(origin: OriginIdentity) -> SwarmCapabilities {
        if !isConnected(origin.key) {
            return .init(canPublish: false,
                         reason: ErrorPayload.Reason.notConnected,
                         limits: .defaults)
        }
        if let reason = nodeFailureReason() {
            return .init(canPublish: false, reason: reason, limits: .defaults)
        }
        return .init(canPublish: true, reason: nil, limits: .defaults)
    }

    /// Caller-origin-scoped — returns `[]` for any origin that has not
    /// created a feed under this app instance. SWIP §"Behavior" makes the
    /// scoping mandatory; cross-origin enumeration would leak feed
    /// existence to other dapps.
    func listFeeds(origin: OriginIdentity) -> [[String: Any]] {
        listFeedsForOrigin(origin.key)
    }

    /// SWIP §"swarm_readFeedEntry". No permission gate (feeds are public
    /// data; the same lookup is available from any bee gateway), the
    /// only pre-flight is HTTP reachability. Param shape:
    /// - exactly one of `topic` (raw 64-hex) or `name` (string for
    ///   `keccak256(origin + "/" + name)` derivation)
    /// - `owner` is required with `topic`; with `name` it falls back to
    ///   the local feed-store record, and is required if no record
    /// - optional `index` — non-negative integer
    func readFeedEntry(params: [String: Any], origin: OriginIdentity) async throws -> [String: Any] {
        // `as? String` collapses both "key absent" and "key present with
        // NSNull" to nil — exactly what we want; the dapp can't
        // distinguish those two on the JSON-RPC wire either.
        let topicString = params["topic"] as? String
        let nameString = params["name"] as? String
        if topicString != nil && nameString != nil {
            throw RouterError.invalidParams(
                reason: nil,
                message: "Provide either topic or name, not both."
            )
        }

        let resolvedIndex: UInt64?
        switch params["index"] {
        case nil, is NSNull:
            resolvedIndex = nil
        case let int as Int where int >= 0:
            resolvedIndex = UInt64(int)
        default:
            throw RouterError.invalidParams(
                reason: nil,
                message: "index must be a non-negative integer."
            )
        }

        let topicHex: String
        let ownerHex: String

        if let topic = topicString {
            guard SwarmRef.isHex(topic, length: 64) else {
                throw RouterError.invalidParams(
                    reason: ErrorPayload.Reason.invalidTopic,
                    message: "topic must be a 64-character hex string."
                )
            }
            topicHex = topic.lowercased()
            guard let owner = (params["owner"] as? String)
                .flatMap(Self.normalizeOwnerHex) else {
                throw RouterError.invalidParams(
                    reason: ErrorPayload.Reason.invalidOwner,
                    message: "owner is required when using topic."
                )
            }
            ownerHex = owner
        } else if let name = nameString {
            guard Self.isValidFeedName(name) else {
                throw RouterError.invalidParams(
                    reason: ErrorPayload.Reason.invalidFeedName,
                    message: "name must be 1-64 chars, no '/', no control chars."
                )
            }
            topicHex = FeedTopic.derive(origin: origin.key, name: name)
            if let providedOwner = params["owner"] as? String {
                guard let normalized = Self.normalizeOwnerHex(providedOwner) else {
                    throw RouterError.invalidParams(
                        reason: ErrorPayload.Reason.invalidOwner,
                        message: "owner must be a 40-character hex address."
                    )
                }
                ownerHex = normalized
            } else if let stored = feedOwner(origin.key, name).flatMap(Self.normalizeOwnerHex) {
                ownerHex = stored
            } else {
                throw RouterError.invalidParams(
                    reason: ErrorPayload.Reason.feedNotFound,
                    message: "Feed not found locally — pass owner explicitly."
                )
            }
        } else {
            throw RouterError.invalidParams(
                reason: nil,
                message: "Either topic or name is required."
            )
        }

        let result: FeedRead
        do {
            result = try await readFeed(ownerHex, topicHex, resolvedIndex)
        } catch FeedReadError.unreachable {
            throw RouterError.nodeUnavailable(reason: ErrorPayload.Reason.nodeStopped)
        } catch FeedReadError.notFound {
            if let index = resolvedIndex {
                throw RouterError.invalidParams(
                    reason: ErrorPayload.Reason.entryNotFound,
                    message: "No entry at index \(index)."
                )
            }
            throw RouterError.invalidParams(
                reason: ErrorPayload.Reason.feedEmpty,
                message: "Feed has no entries."
            )
        } catch {
            throw RouterError.internalError(message: "\(error)")
        }

        // SWIP §"swarm_readFeedEntry" Result — `nextIndex` is only
        // populated when reading the latest entry. `NSNull` (rather
        // than dropping the key) so JSCore surfaces a real `null` to
        // the dapp instead of `undefined`.
        var dict: [String: Any] = [
            "data": result.payload.base64EncodedString(),
            "encoding": "base64",
            "index": Int(result.index),
            "nextIndex": NSNull(),
        ]
        if resolvedIndex == nil, let next = result.nextIndex {
            dict["nextIndex"] = Int(next)
        }
        return dict
    }

    /// Returns lowercased 40-char hex, no `0x` prefix. `nil` for any
    /// input that doesn't match the canonical Ethereum-address shape.
    private static func normalizeOwnerHex(_ raw: String) -> String? {
        let prefixed = Hex.prefixed(raw)
        guard Hex.isAddressShape(prefixed) else { return nil }
        return Hex.stripped(prefixed).lowercased()
    }

    /// SWIP §"swarm_createFeed" name rules — 1-64 chars, no `/`, no
    /// control. Internal so `SwarmBridge.handleCreateFeed` shares the
    /// same check `readFeedEntry` does without duplicating it.
    static func isValidFeedName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64, !name.contains("/") else { return false }
        return name.unicodeScalars.allSatisfy { $0.value >= 32 }
    }

    /// Map `RouterError` to the wire-format envelope. Bridge calls this
    /// after `handle` throws so the JSON reply always carries an
    /// EIP-1193-shaped error.
    func errorPayload(for error: Swift.Error) -> ErrorPayload {
        guard let routerError = error as? RouterError else {
            return ErrorPayload(code: ErrorPayload.Code.internalError,
                                message: "\(error)", dataReason: nil)
        }
        switch routerError {
        case .unsupportedMethod(let method):
            return ErrorPayload(code: ErrorPayload.Code.unsupportedMethod,
                                message: "Method not supported: \(method)",
                                dataReason: nil)
        case .invalidParams(let reason, let message):
            return ErrorPayload(code: ErrorPayload.Code.invalidParams,
                                message: message, dataReason: reason)
        case .nodeUnavailable(let reason):
            return ErrorPayload(code: ErrorPayload.Code.nodeUnavailable,
                                message: "Node unavailable: \(reason)",
                                dataReason: reason)
        case .internalError(let message):
            return ErrorPayload(code: ErrorPayload.Code.internalError,
                                message: message, dataReason: nil)
        }
    }
}
