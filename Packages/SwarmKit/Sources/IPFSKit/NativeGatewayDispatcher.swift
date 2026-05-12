import Foundation
import os.log

/// Capture during smoke with:
/// `log stream --predicate 'subsystem == "com.browser.Freedom.native"' --style ndjson`
private let logger = Logger(subsystem: "com.browser.Freedom.native", category: "dispatcher")

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

    public func start() {
        lock.lock()
        guard worker == nil, !state.stopped else { lock.unlock(); return }
        lock.unlock()
        let thread = Thread { [weak self] in self?.runLoop() }
        thread.name = "freedom.ipfs.native-dispatcher"
        thread.qualityOfService = .userInitiated
        worker = thread
        thread.start()
        logger.info("dispatcher started")
    }

    /// Idempotent. Drained sinks receive a synthetic cancelled event
    /// stamped with their registered handle id — so the sink's own
    /// boundary check (`event.requestHandle == handle.id`) doesn't
    /// reject the drain.
    public func stop() {
        let drained: [(UInt64, NativeRequestSink)]
        lock.lock()
        if state.stopped { lock.unlock(); return }
        state.stopped = true
        drained = state.sinks.map { ($0.key, $0.value) }
        state.sinks.removeAll()
        state.stashedEvents.removeAll()
        state.tombstones.removeAll()
        lock.unlock()
        logger.info("dispatcher stop drained=\(drained.count, privacy: .public)")
        for (handleID, sink) in drained {
            sink.nativeRequestReceivedEvent(
                FreedomIpfsNativeGatewayEvent(
                    status: .gatewayStopped,
                    events: [.cancelled, .handleFreed],
                    requestHandle: handleID
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
            logger.info("register handle=\(handleID, privacy: .public) afterStop=true")
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
        logger.debug("register handle=\(handleID, privacy: .public) replay=\(replay.count, privacy: .public)")
        for event in replay {
            sink.nativeRequestReceivedEvent(event)
        }
    }

    /// Tombstone until Rust emits `.handleFreed`.
    public func unregister(handleID: UInt64) {
        lock.lock()
        state.sinks.removeValue(forKey: handleID)
        state.stashedEvents.removeValue(forKey: handleID)
        state.tombstones.insert(handleID)
        lock.unlock()
        logger.debug("unregister handle=\(handleID, privacy: .public)")
    }

    private func runLoop() {
        logger.info("worker started")
        while true {
            let stopped = lock.withLock { state.stopped }
            if stopped {
                logger.info("worker exit reason=stopped")
                return
            }
            let event: FreedomIpfsNativeGatewayEvent
            do {
                event = try eventSource.waitNextNativeGatewayEvent(timeoutMilliseconds: 200)
            } catch {
                lock.withLock { state.stopped = true }
                logger.error("worker exit reason=waitError")
                return
            }
            switch event.status {
            case .timeout:
                continue
            case .invalidNode, .gatewayStopped:
                lock.withLock { state.stopped = true }
                logger.info("worker exit reason=\(String(describing: event.status), privacy: .public)")
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
                return .tombstoneDrop
            }
            state.stashedEvents[handleID, default: []].append(event)
            return .stash
        }
        switch action {
        case .invoke(let sink):
            logger.debug("event handle=\(handleID, privacy: .public) flags=\(NativeGatewayDispatcher.flagsDescription(event.events), privacy: .public) action=route")
            sink.nativeRequestReceivedEvent(event)
        case .stash:
            logger.debug("event handle=\(handleID, privacy: .public) flags=\(NativeGatewayDispatcher.flagsDescription(event.events), privacy: .public) action=stash")
        case .tombstoneDrop:
            logger.debug("event handle=\(handleID, privacy: .public) flags=\(NativeGatewayDispatcher.flagsDescription(event.events), privacy: .public) action=drop")
        }
    }

    private static func flagsDescription(_ flags: FreedomIpfsNativeGatewayEventFlags) -> String {
        var parts: [String] = []
        if flags.contains(.responseReady) { parts.append("responseReady") }
        if flags.contains(.bodyReady) { parts.append("bodyReady") }
        if flags.contains(.end) { parts.append("end") }
        if flags.contains(.failed) { parts.append("failed") }
        if flags.contains(.cancelled) { parts.append("cancelled") }
        if flags.contains(.handleFreed) { parts.append("handleFreed") }
        return parts.isEmpty ? "none" : parts.joined(separator: "|")
    }

    private enum RouteAction {
        case invoke(NativeRequestSink)
        case stash
        case tombstoneDrop
    }
}
