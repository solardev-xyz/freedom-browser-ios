import Foundation

/// Why a source could not answer, when the router should remember it.
/// Desktop `failureKind`: a timeout opens an escalating cooldown for
/// the route; a capacity failure (the source's execution ceiling) is a
/// capability boundary and blocks the route for the session.
enum ChainSourceFailureKind: Sendable {
    case timeout
    case capacity
}

extension ChainSourceUnavailable {
    init(reason: String, kind: ChainSourceFailureKind?) {
        self.init(reason: reason)
        self.failureKind = kind
    }

    /// Desktop `isCapacityFailure`: an "out of gas" / execution-limit
    /// message from a source's local EVM means the call is beyond what
    /// that source can execute, whatever the load.
    static func isCapacityMessage(_ message: String) -> Bool {
        message.range(
            of: #"out of gas|execution (?:gas|resource) limit|exceeds? (?:the )?(?:gas|execution) limit"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}

/// A source did not answer inside the wait the router allowed it.
/// The work itself may still be running (Myotis and Colibri calls are
/// not cancellable) — only the caller has moved on.
struct ChainSourceDeadline: Error, LocalizedError {
    let source: ChainSource
    let seconds: TimeInterval

    var errorDescription: String? {
        "\(source.displayName) exceeded its \(Int(seconds * 1_000))ms deadline"
    }
}

/// Process-local memory of which (source, chain, page, method, target)
/// routes a source is currently struggling with. Deliberately not
/// persisted and not per chain policy: a source that cannot keep up
/// with one app's call shape must not reorder the user's chain policy,
/// affect another app, or stay demoted after a restart. Desktop
/// `adaptiveSourceState`.
@MainActor
final class AdaptiveRouting {
    struct RouteState {
        var timeoutCount = 0
        var openUntil: Date = .distantPast
        var sessionBlocked = false
    }

    /// Escalating cooldowns after successive timeouts on one route.
    static let timeoutCooldowns: [TimeInterval] = [15, 30, 60]
    static let maxRoutes = 1_024

    private var states: [String: RouteState] = [:]
    /// Insertion order for FIFO eviction at `maxRoutes`.
    private var order: [String] = []
    private let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    /// Desktop `adaptiveRouteKey`: nil for wallet-internal reads, which
    /// never take part in the adaptive layer.
    static func routeKey(
        source: ChainSource, chainID: Int, method: String, params: [Any], context: RoutingContext
    ) -> String? {
        guard let origin = context.origin else { return nil }
        return [source.rawValue, String(chainID), origin, method, requestTarget(method: method, params: params)]
            .joined(separator: "\u{1F}")
    }

    /// The contract or account a read is about, lowercased; `*` when the
    /// method has no such target. Desktop `requestTarget`.
    static func requestTarget(method: String, params: [Any]) -> String {
        var target: Any?
        switch method {
        case "eth_call", "eth_estimateGas":
            target = (params.first as? [String: Any])?["to"]
        case "eth_getBalance", "eth_getCode", "eth_getStorageAt", "eth_getTransactionCount":
            target = params.first
        case "eth_getLogs":
            target = (params.first as? [String: Any])?["address"]
        default:
            break
        }
        if let list = target as? [Any] {
            let addresses = list.compactMap { ($0 as? String).flatMap(normalizedAddress) }.sorted()
            return addresses.isEmpty ? "*" : addresses.joined(separator: ",")
        }
        return (target as? String).flatMap(normalizedAddress) ?? "*"
    }

    private static func normalizedAddress(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.range(of: #"^0x[0-9a-fA-F]{40}$"#, options: .regularExpression) != nil else { return nil }
        return s.lowercased()
    }

    /// The route is on cooldown or blocked for the session.
    func isBypassed(_ key: String?) -> Bool {
        guard let key, let state = states[key] else { return false }
        return state.sessionBlocked || state.openUntil > clock()
    }

    /// Why the route is bypassed, for the log.
    func bypassReason(_ key: String?) -> String? {
        guard let key, let state = states[key] else { return nil }
        if state.sessionBlocked { return "blocked for this session (execution limit)" }
        let remaining = state.openUntil.timeIntervalSince(clock())
        return remaining > 0 ? "cooling down for \(Int(remaining.rounded(.up)))s" : nil
    }

    /// A deterministic execution ceiling is a capability boundary for
    /// this app session, not a health fluctuation: a lighter call
    /// succeeding against the same contract must not erase it.
    func recordSuccess(_ key: String?) {
        guard let key, states[key]?.sessionBlocked != true else { return }
        remove(key)
    }

    func recordFailure(_ key: String?, kind: ChainSourceFailureKind?) {
        guard let key, let kind else { return }
        var state = states[key] ?? RouteState()
        switch kind {
        case .capacity:
            state.sessionBlocked = true
        case .timeout:
            state.timeoutCount += 1
            let cooldown = Self.timeoutCooldowns[min(state.timeoutCount, Self.timeoutCooldowns.count) - 1]
            state.openUntil = clock().addingTimeInterval(cooldown)
        }
        set(key, state)
    }

    func state(_ key: String) -> RouteState? { states[key] }
    var count: Int { states.count }

    private func set(_ key: String, _ state: RouteState) {
        if states[key] == nil {
            if states.count >= Self.maxRoutes, let oldest = order.first {
                order.removeFirst()
                states.removeValue(forKey: oldest)
            }
            order.append(key)
        }
        states[key] = state
    }

    private func remove(_ key: String) {
        guard states.removeValue(forKey: key) != nil else { return }
        order.removeAll { $0 == key }
    }
}

/// Admission control for the two sources whose work cannot be
/// cancelled once started. Myotis executes one read at a time per
/// chain (the engine's native admission) with a bounded wait queue;
/// Colibri keeps a global and a per-route cap. A caller's deadline
/// bounds its *wait*; the slot is held until the work settles.
/// Desktop `myotisSlots` / `colibriInFlight`.
@MainActor
final class SourceAdmission {
    static let maxMyotisInFlight = 1
    static let maxMyotisQueued = 16
    static let maxColibriInFlight = 8
    static let maxColibriInFlightPerRoute = 2

    /// A queued Myotis caller. `wait()` returns once the slot is handed
    /// over; `abandon()` is called when the caller's deadline fired.
    final class Waiter {
        fileprivate var continuation: CheckedContinuation<Void, Never>?
        fileprivate(set) var granted = false
        fileprivate(set) var abandoned = false

        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                if granted { c.resume() } else { continuation = c }
            }
        }
    }

    enum MyotisSlot {
        /// The slot was free; no timer is needed.
        case immediate
        case queued(Waiter)
    }

    private var myotisInFlight: [Int: Int] = [:]
    private var myotisWaiters: [Int: [Waiter]] = [:]
    private var colibriInFlight = 0
    private var colibriByRoute: [String: Int] = [:]

    init() {}

    // MARK: Myotis

    /// Nil when the queue is full: past that depth the slot is
    /// demonstrably not turning over inside anyone's deadline.
    func acquireMyotis(chainID: Int) -> MyotisSlot? {
        if myotisInFlight[chainID, default: 0] < Self.maxMyotisInFlight {
            myotisInFlight[chainID, default: 0] += 1
            return .immediate
        }
        if myotisWaiters[chainID, default: []].count >= Self.maxMyotisQueued { return nil }
        let waiter = Waiter()
        myotisWaiters[chainID, default: []].append(waiter)
        return .queued(waiter)
    }

    /// Hands the slot straight to the next live waiter rather than
    /// counting it down and back up.
    func releaseMyotis(chainID: Int) {
        while !myotisWaiters[chainID, default: []].isEmpty {
            let next = myotisWaiters[chainID]!.removeFirst()
            if next.abandoned { continue }
            next.granted = true
            next.continuation?.resume()
            next.continuation = nil
            return
        }
        myotisInFlight[chainID] = max(0, myotisInFlight[chainID, default: 0] - 1)
    }

    /// The caller's deadline fired while queued. If the slot was handed
    /// over in the meantime, pass it along rather than leaking it to a
    /// caller that has already fallen through.
    func abandonMyotis(chainID: Int, waiter: Waiter) {
        if waiter.granted {
            releaseMyotis(chainID: chainID)
        } else {
            waiter.abandoned = true
            myotisWaiters[chainID]?.removeAll { $0 === waiter }
        }
    }

    func myotisInFlightCount(chainID: Int) -> Int { myotisInFlight[chainID, default: 0] }
    func myotisQueueDepth(chainID: Int) -> Int { myotisWaiters[chainID, default: []].count }

    // MARK: Colibri

    /// False when the prover is already saturated globally or for this
    /// route — the caller falls through instead of parking more work.
    func admitColibri(routeKey: String) -> Bool {
        guard colibriInFlight < Self.maxColibriInFlight,
              colibriByRoute[routeKey, default: 0] < Self.maxColibriInFlightPerRoute else { return false }
        colibriInFlight += 1
        colibriByRoute[routeKey, default: 0] += 1
        return true
    }

    func releaseColibri(routeKey: String) {
        colibriInFlight = max(0, colibriInFlight - 1)
        let remaining = colibriByRoute[routeKey, default: 1] - 1
        if remaining > 0 { colibriByRoute[routeKey] = remaining } else { colibriByRoute.removeValue(forKey: routeKey) }
    }

    var colibriInFlightCount: Int { colibriInFlight }
}

/// Resolves once, with whichever outcome arrives first; later outcomes
/// are dropped. The bridge between "the work settled" and "the caller
/// stopped waiting" that lets a deadline win without cancelling — or
/// waiting for — the work behind it.
@MainActor
final class FirstSettled<T> {
    private var pending: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?
    private var done = false

    init() {}

    func settle(_ result: Result<T, Error>) {
        guard !done else { return }
        done = true
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else {
            pending = result
        }
    }

    func wait() async throws -> T {
        if let pending { return try pending.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

/// Bound a wait without cancelling the work behind it. `operation` runs
/// in its own task and keeps running after the deadline fires; the
/// caller gets `ChainSourceDeadline` and moves on. A `Task.value`
/// awaited inside `operation` is not interruptible by cancellation,
/// which is exactly why this is not a task group race: the group would
/// have to drain the child that is still waiting on the engine.
@MainActor
func withSourceDeadline<T: Sendable>(
    _ seconds: TimeInterval,
    source: ChainSource,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let first = FirstSettled<T>()
    let work = Task { @MainActor in
        let outcome: Result<T, Error>
        do { outcome = .success(try await operation()) } catch { outcome = .failure(error) }
        first.settle(outcome)
    }
    let timer = Task { @MainActor in
        try? await Task.sleep(for: .seconds(max(0.001, seconds)))
        guard !Task.isCancelled else { return }
        first.settle(.failure(ChainSourceDeadline(source: source, seconds: seconds)))
    }
    defer { timer.cancel() }
    _ = work
    return try await withTaskCancellationHandler {
        try await first.wait()
    } onCancel: {
        Task { @MainActor in first.settle(.failure(CancellationError())) }
    }
}
