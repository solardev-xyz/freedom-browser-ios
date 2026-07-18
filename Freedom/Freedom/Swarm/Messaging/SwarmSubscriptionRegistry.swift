import Foundation

/// App-wide bookkeeping for `swarm_subscribe` pipelines — desktop's
/// `subscription-registry.js` ported to the bridge graph:
///
/// - **One pipeline per `(kind, key)`**: N subscriptions to the same
///   GSOC address / PSS topic share one gateway WebSocket, fanned out
///   to every subscription's deliver closure.
/// - **Per-origin cap** (`SwarmCapabilities.Limits.maxSubscriptions`):
///   exceeding it throws `tooManySubscriptions` (-32602); the node's
///   own lurker-pool exhaustion arrives from the socket as
///   `nodeSubscriptionLimit` and maps to a retryable 4900.
/// - **Teardown**: per-owner (tab navigation / close), per-origin
///   (permission revoke — subscribed to `.swarmPermissionRevoked`
///   here so revocation works even with no bridge alive), and
///   per-subscription (`swarm_unsubscribe`).
///
/// One instance per app session, injected via `SwarmServices`.
@MainActor
final class SwarmSubscriptionRegistry {
    typealias Connect = @MainActor (_ kind: String, _ key: String) -> any SwarmSubscriptionHandle

    enum RegistryError: Swift.Error, Equatable {
        case tooManySubscriptions
        case nodeSubscriptionLimit
        case unreachable
    }

    struct Subscription {
        let id: String
        let origin: String
        /// Identity of the hosting bridge/tab — teardown key for
        /// navigation and tab close.
        let owner: ObjectIdentifier
        let kind: String
        let key: String
        /// Emits the SWIP `message`-event payload into this
        /// subscription's page.
        let deliver: @MainActor ([String: Any]) -> Void
    }

    private struct Pipeline {
        let handle: any SwarmSubscriptionHandle
        var subscriptionIDs: Set<String>
    }

    private let connect: Connect
    private let maxSubscriptionsPerOrigin: Int
    private var subscriptions: [String: Subscription] = [:]
    private var pipelines: [String: Pipeline] = [:]
    private var revocationObserver: (any NSObjectProtocol)?

    init(
        connect: @escaping Connect = { kind, key in
            SwarmSubscriptionSocket(kind: kind, key: key)
        },
        maxSubscriptionsPerOrigin: Int = SwarmCapabilities.Limits.defaults.maxSubscriptions
    ) {
        self.connect = connect
        self.maxSubscriptionsPerOrigin = maxSubscriptionsPerOrigin
        revocationObserver = NotificationCenter.default.addObserver(
            forName: .swarmPermissionRevoked, object: nil, queue: .main
        ) { [weak self] notification in
            guard let origin = notification.userInfo?["origin"] as? String else { return }
            MainActor.assumeIsolated { self?.cancelByOrigin(origin) }
        }
    }

    /// Opens (or joins) the pipeline for `(kind, key)` and registers a
    /// subscription. Awaits establishment for a new pipeline; joining
    /// an existing one is immediate.
    func subscribe(
        origin: String,
        owner: ObjectIdentifier,
        kind: String,
        key: String,
        deliver: @escaping @MainActor ([String: Any]) -> Void
    ) async throws -> String {
        guard subscriptions.values.filter({ $0.origin == origin }).count
                < maxSubscriptionsPerOrigin else {
            throw RegistryError.tooManySubscriptions
        }

        let socketKey = "\(kind):\(key)"
        if pipelines[socketKey] == nil {
            let handle = connect(kind, key)
            handle.onMessage = { [weak self] payload in
                self?.fanOut(socketKey: socketKey, payload: payload)
            }
            // Reserve the slot before awaiting so a concurrent
            // subscribe to the same key joins instead of double-dialing.
            pipelines[socketKey] = Pipeline(handle: handle, subscriptionIDs: [])
            do {
                try await handle.establish()
            } catch {
                pipelines.removeValue(forKey: socketKey)?.handle.cancel()
                switch error {
                case SwarmSubscriptionError.nodeSubscriptionLimit:
                    throw RegistryError.nodeSubscriptionLimit
                default:
                    throw RegistryError.unreachable
                }
            }
        }

        let id = Self.makeSubscriptionID()
        subscriptions[id] = Subscription(
            id: id, origin: origin, owner: owner,
            kind: kind, key: key, deliver: deliver
        )
        pipelines[socketKey]?.subscriptionIDs.insert(id)
        return id
    }

    /// Origin-scoped close. `false` when no live subscription with
    /// this id belongs to `origin` → `subscription_not_found`.
    func unsubscribe(origin: String, id: String) -> Bool {
        guard let sub = subscriptions[id], sub.origin == origin else {
            return false
        }
        remove(sub)
        return true
    }

    /// Tab navigated away or closed — SWIP: subscriptions are
    /// session-scoped and MUST be torn down on page unload.
    func cancelByOwner(_ owner: ObjectIdentifier) {
        for sub in subscriptions.values where sub.owner == owner {
            remove(sub)
        }
    }

    /// Permission revoked — SWIP revocation rule.
    func cancelByOrigin(_ origin: String) {
        for sub in subscriptions.values where sub.origin == origin {
            remove(sub)
        }
    }

    func activeCount(origin: String) -> Int {
        subscriptions.values.filter { $0.origin == origin }.count
    }

    private func remove(_ sub: Subscription) {
        subscriptions.removeValue(forKey: sub.id)
        let socketKey = "\(sub.kind):\(sub.key)"
        guard var pipeline = pipelines[socketKey] else { return }
        pipeline.subscriptionIDs.remove(sub.id)
        if pipeline.subscriptionIDs.isEmpty {
            pipeline.handle.cancel()
            pipelines.removeValue(forKey: socketKey)
        } else {
            pipelines[socketKey] = pipeline
        }
    }

    private func fanOut(socketKey: String, payload: Data) {
        guard let pipeline = pipelines[socketKey] else { return }
        let receivedAt = Int(Date().timeIntervalSince1970 * 1000)
        for id in pipeline.subscriptionIDs {
            guard let sub = subscriptions[id] else { continue }
            // SWIP messaging §"Events" — SubscriptionMessage.
            sub.deliver([
                "type": "swarm_subscription",
                "subscription": sub.id,
                "result": [
                    "kind": sub.kind,
                    "key": sub.key,
                    "data": payload.base64EncodedString(),
                    "encoding": "base64",
                    "receivedAt": receivedAt,
                ],
            ])
        }
    }

    /// 32-hex opaque id, unique per session (desktop parity).
    private static func makeSubscriptionID() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
