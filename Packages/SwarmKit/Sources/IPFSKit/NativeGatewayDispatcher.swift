import Foundation

/// Sink that receives native gateway events for a single in-flight
/// request. Invoked off the main actor by the dispatcher worker — do
/// any blocking FFI work here, then hop to main for WebKit delivery.
public protocol NativeRequestSink: AnyObject, Sendable {
    func nativeRequestReceivedEvent(_ event: FreedomIpfsNativeGatewayEvent)
}

/// Source of native gateway events. `FreedomIpfsReader` conforms; tests
/// inject a fake to drive the dispatcher without a real Rust node.
public protocol NativeGatewayEventSource: Sendable {
    func waitNextNativeGatewayEvent(timeoutMilliseconds: UInt64) throws -> FreedomIpfsNativeGatewayEvent
}

extension FreedomIpfsReader: NativeGatewayEventSource {}

/// Routes events from the Rust node-level event multiplexer
/// (`freedom_ipfs_gateway_wait_next_event`) to per-request sinks.
/// One dispatcher per `IPFSNode` lifecycle.
///
/// Concurrency contract:
/// - Public API is thread-safe via an internal lock.
/// - One worker thread runs `waitNextNativeGatewayEvent` in a loop.
/// - The worker calls `sink.nativeRequestReceivedEvent` outside the
///   lock so a slow sink doesn't block registration of new requests.
/// - On stop, registered sinks receive a synthetic cancelled event
///   so they can clean up their WebKit-side state.
public final class NativeGatewayDispatcher: @unchecked Sendable {
    private let eventSource: NativeGatewayEventSource
    private let lock = NSLock()
    private var state = State()
    private var worker: Thread?

    private struct State {
        var sinks: [UInt64: NativeRequestSink] = [:]
        /// Events for handles that arrived before the registration
        /// finished. Replayed on register.
        var stashedEvents: [UInt64: [FreedomIpfsNativeGatewayEvent]] = [:]
        /// Handles that were explicitly unregistered. Future events
        /// for these are dropped, not stashed. Cleared on `.handleFreed`.
        var tombstones: Set<UInt64> = []
        var stopped: Bool = false
    }

    public init(eventSource: NativeGatewayEventSource) {
        self.eventSource = eventSource
    }

    /// Start the worker thread. Idempotent.
    public func start() {
        lock.lock()
        guard worker == nil, !state.stopped else { lock.unlock(); return }
        lock.unlock()
        let thread = Thread { [weak self] in self?.runLoop() }
        thread.name = "freedom.ipfs.native-dispatcher"
        thread.qualityOfService = .userInitiated
        worker = thread
        thread.start()
    }

    /// Stop the worker, drain the registry, and notify any
    /// outstanding sinks with a synthetic cancelled event so they
    /// can clean up. Idempotent.
    public func stop() {
        let drainedSinks: [NativeRequestSink]
        lock.lock()
        if state.stopped { lock.unlock(); return }
        state.stopped = true
        drainedSinks = Array(state.sinks.values)
        state.sinks.removeAll()
        state.stashedEvents.removeAll()
        state.tombstones.removeAll()
        lock.unlock()
        for sink in drainedSinks {
            sink.nativeRequestReceivedEvent(
                FreedomIpfsNativeGatewayEvent(
                    status: .gatewayStopped,
                    events: [.cancelled, .handleFreed],
                    requestHandle: 0
                )
            )
        }
    }

    /// Register a sink for the given handle. Replays any events that
    /// arrived during the start-then-register race window. Call this
    /// while holding the same lock that protects request start, so the
    /// dispatcher can never race past us. See `IPFSNode.startNativeGatewayRequest`.
    public func register(handleID: UInt64, sink: NativeRequestSink) {
        let replay: [FreedomIpfsNativeGatewayEvent]
        lock.lock()
        if state.stopped {
            lock.unlock()
            sink.nativeRequestReceivedEvent(
                FreedomIpfsNativeGatewayEvent(
                    status: .gatewayStopped,
                    events: [.cancelled, .handleFreed],
                    requestHandle: handleID
                )
            )
            return
        }
        state.sinks[handleID] = sink
        replay = state.stashedEvents.removeValue(forKey: handleID) ?? []
        lock.unlock()
        for event in replay {
            sink.nativeRequestReceivedEvent(event)
        }
    }

    /// Tombstone the handle: drop the sink and any stashed events,
    /// and silence future events for this handle until Rust emits
    /// `.handleFreed`. Used by `webView(_:stop:)`-style cancellations.
    public func unregister(handleID: UInt64) {
        lock.lock()
        state.sinks.removeValue(forKey: handleID)
        state.stashedEvents.removeValue(forKey: handleID)
        state.tombstones.insert(handleID)
        lock.unlock()
    }

    // MARK: - Worker

    private func runLoop() {
        while true {
            let stopped = lock.withLock { state.stopped }
            if stopped { return }
            let event: FreedomIpfsNativeGatewayEvent
            do {
                event = try eventSource.waitNextNativeGatewayEvent(timeoutMilliseconds: 200)
            } catch {
                lock.withLock { state.stopped = true }
                return
            }
            switch event.status {
            case .timeout:
                continue
            case .invalidNode, .gatewayStopped:
                lock.withLock { state.stopped = true }
                return
            case .ok:
                route(event)
            }
        }
    }

    private func route(_ event: FreedomIpfsNativeGatewayEvent) {
        let handleID = event.requestHandle
        let isHandleFreed = event.events.contains(.handleFreed)
        let action: RouteAction = lock.withLock {
            if let sink = state.sinks[handleID] {
                if isHandleFreed {
                    state.sinks.removeValue(forKey: handleID)
                    state.stashedEvents.removeValue(forKey: handleID)
                    state.tombstones.remove(handleID)
                }
                return .invoke(sink)
            }
            if state.tombstones.contains(handleID) {
                if isHandleFreed {
                    state.tombstones.remove(handleID)
                }
                return .drop
            }
            state.stashedEvents[handleID, default: []].append(event)
            return .drop
        }
        if case .invoke(let sink) = action {
            sink.nativeRequestReceivedEvent(event)
        }
    }

    private enum RouteAction {
        case invoke(NativeRequestSink)
        case drop
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
