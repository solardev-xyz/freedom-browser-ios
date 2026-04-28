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

    init(
        isConnected: @escaping @MainActor (String) -> Bool,
        listFeedsForOrigin: @escaping @MainActor (String) -> [[String: Any]],
        nodeFailureReason: @escaping @MainActor () -> String?
    ) {
        self.isConnected = isConnected
        self.listFeedsForOrigin = listFeedsForOrigin
        self.nodeFailureReason = nodeFailureReason
    }

    func handle(method: String, params: [String: Any], origin: OriginIdentity) async throws -> Any {
        switch method {
        case "swarm_getCapabilities":
            return capabilities(origin: origin).asJSONDict
        case "swarm_listFeeds":
            return listFeeds(origin: origin)
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
