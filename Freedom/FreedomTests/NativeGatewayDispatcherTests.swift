import XCTest
@testable import IPFSKit

/// Adapter tests for `NativeGatewayDispatcher`. Drives the dispatcher
/// via a fake event source, so no Rust node is required.
final class NativeGatewayDispatcherTests: XCTestCase {
    func testEventForRegisteredSinkIsRouted() throws {
        let source = FakeEventSource()
        let dispatcher = NativeGatewayDispatcher(eventSource: source)
        dispatcher.start()
        defer { dispatcher.stop(); source.shutdown() }

        let sink = RecordingSink()
        dispatcher.register(handleID: 42, sink: sink)

        source.enqueue(makeEvent(handle: 42, flags: [.responseReady]))

        let events = try waitForEvents(sink: sink, count: 1)
        XCTAssertEqual(events.first?.requestHandle, 42)
        XCTAssertEqual(events.first?.events, [.responseReady])
    }

    func testEventForUnknownHandleIsStashedAndReplayedOnRegister() throws {
        let source = FakeEventSource()
        let dispatcher = NativeGatewayDispatcher(eventSource: source)
        dispatcher.start()
        defer { dispatcher.stop(); source.shutdown() }

        // Event arrives BEFORE any sink is registered for handle 42.
        source.enqueue(makeEvent(handle: 42, flags: [.responseReady]))
        // Give the worker a chance to consume into the stash.
        Thread.sleep(forTimeInterval: 0.05)

        let sink = RecordingSink()
        dispatcher.register(handleID: 42, sink: sink)

        let events = try waitForEvents(sink: sink, count: 1)
        XCTAssertEqual(events.first?.requestHandle, 42)
    }

    func testTombstoneDropsLateEventsForUnregisteredHandle() throws {
        let source = FakeEventSource()
        let dispatcher = NativeGatewayDispatcher(eventSource: source)
        dispatcher.start()
        defer { dispatcher.stop(); source.shutdown() }

        let sink = RecordingSink()
        dispatcher.register(handleID: 42, sink: sink)
        dispatcher.unregister(handleID: 42)

        source.enqueue(makeEvent(handle: 42, flags: [.cancelled]))
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertTrue(sink.snapshot().isEmpty, "Tombstoned handle should drop late events")
    }

    func testHandleFreedClearsRegistry() throws {
        let source = FakeEventSource()
        let dispatcher = NativeGatewayDispatcher(eventSource: source)
        dispatcher.start()
        defer { dispatcher.stop(); source.shutdown() }

        let sink = RecordingSink()
        dispatcher.register(handleID: 42, sink: sink)
        source.enqueue(makeEvent(handle: 42, flags: [.handleFreed]))

        _ = try waitForEvents(sink: sink, count: 1)

        // After .handleFreed, subsequent events for the same id should
        // NOT reach the original sink (it's been removed from registry).
        source.enqueue(makeEvent(handle: 42, flags: [.bodyReady]))
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(sink.snapshot().count, 1, "No more events should land on the sink after .handleFreed")
    }

    func testMultipleSinksRouteIndependently() throws {
        let source = FakeEventSource()
        let dispatcher = NativeGatewayDispatcher(eventSource: source)
        dispatcher.start()
        defer { dispatcher.stop(); source.shutdown() }

        let sinkA = RecordingSink()
        let sinkB = RecordingSink()
        dispatcher.register(handleID: 1, sink: sinkA)
        dispatcher.register(handleID: 2, sink: sinkB)

        source.enqueue(makeEvent(handle: 1, flags: [.responseReady]))
        source.enqueue(makeEvent(handle: 2, flags: [.responseReady]))
        source.enqueue(makeEvent(handle: 1, flags: [.bodyReady]))

        let aEvents = try waitForEvents(sink: sinkA, count: 2)
        let bEvents = try waitForEvents(sink: sinkB, count: 1)
        XCTAssertEqual(aEvents.map { $0.requestHandle }, [1, 1])
        XCTAssertEqual(bEvents.map { $0.requestHandle }, [2])
    }

    func testStopDrainsRegisteredSinksWithSyntheticCancel() throws {
        let source = FakeEventSource()
        let dispatcher = NativeGatewayDispatcher(eventSource: source)
        dispatcher.start()
        defer { source.shutdown() }

        let sinkA = RecordingSink()
        let sinkB = RecordingSink()
        dispatcher.register(handleID: 1, sink: sinkA)
        dispatcher.register(handleID: 2, sink: sinkB)

        dispatcher.stop()

        // Both sinks should have received a synthetic cancel+handleFreed
        // event so they can clean up their WK state.
        let aEvents = try waitForEvents(sink: sinkA, count: 1)
        let bEvents = try waitForEvents(sink: sinkB, count: 1)
        XCTAssertEqual(aEvents.first?.status, .gatewayStopped)
        XCTAssertTrue(aEvents.first!.events.contains(.cancelled))
        XCTAssertTrue(aEvents.first!.events.contains(.handleFreed))
        XCTAssertEqual(bEvents.first?.status, .gatewayStopped)
    }

    func testRegisterAfterStopImmediatelyDrains() throws {
        let source = FakeEventSource()
        let dispatcher = NativeGatewayDispatcher(eventSource: source)
        dispatcher.start()
        defer { source.shutdown() }

        dispatcher.stop()

        let sink = RecordingSink()
        dispatcher.register(handleID: 42, sink: sink)
        let events = try waitForEvents(sink: sink, count: 1)
        XCTAssertEqual(events.first?.status, .gatewayStopped)
    }

    func testGatewayStoppedStatusExitsWorker() throws {
        let source = FakeEventSource()
        let dispatcher = NativeGatewayDispatcher(eventSource: source)
        dispatcher.start()
        defer { dispatcher.stop(); source.shutdown() }

        // Drive the worker into a terminal status.
        source.enqueueStatus(.gatewayStopped)
        Thread.sleep(forTimeInterval: 0.1)

        // After the worker exits, registering a new sink should hit
        // the "stopped" path and synthesize a cancel.
        let sink = RecordingSink()
        dispatcher.register(handleID: 42, sink: sink)
        let events = try waitForEvents(sink: sink, count: 1)
        XCTAssertEqual(events.first?.status, .gatewayStopped)
    }

    // MARK: - Test helpers

    private func makeEvent(
        handle: UInt64,
        flags: FreedomIpfsNativeGatewayEventFlags
    ) -> FreedomIpfsNativeGatewayEvent {
        FreedomIpfsNativeGatewayEvent(status: .ok, events: flags, requestHandle: handle)
    }

    /// Poll a sink until it has at least `count` events or the
    /// deadline expires. Avoids flakiness from event delivery on the
    /// dispatcher worker thread.
    private func waitForEvents(
        sink: RecordingSink,
        count: Int,
        timeout: TimeInterval = 1.0
    ) throws -> [FreedomIpfsNativeGatewayEvent] {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            let events = sink.snapshot()
            if events.count >= count {
                return events
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let got = sink.snapshot()
        XCTFail("Expected at least \(count) event(s) within \(timeout)s, got \(got.count)")
        return got
    }
}

// MARK: - Fakes

private final class RecordingSink: NativeRequestSink, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [FreedomIpfsNativeGatewayEvent] = []

    func nativeRequestReceivedEvent(_ event: FreedomIpfsNativeGatewayEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [FreedomIpfsNativeGatewayEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

/// Blocking-wait event source backed by an in-memory queue and a
/// condition variable. Mimics the Rust event-mux contract: `waitNext`
/// returns the next event if available, otherwise blocks until one is
/// enqueued or the timeout expires.
private final class FakeEventSource: NativeGatewayEventSource, @unchecked Sendable {
    private let condition = NSCondition()
    private var queue: [FreedomIpfsNativeGatewayEvent] = []
    private var shutdownRequested = false

    func waitNextNativeGatewayEvent(timeoutMilliseconds: UInt64) throws -> FreedomIpfsNativeGatewayEvent {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: TimeInterval(timeoutMilliseconds) / 1000)
        while queue.isEmpty && !shutdownRequested {
            if !condition.wait(until: deadline) { break }
        }
        if shutdownRequested {
            return FreedomIpfsNativeGatewayEvent(
                status: .gatewayStopped,
                events: [],
                requestHandle: 0
            )
        }
        if !queue.isEmpty {
            return queue.removeFirst()
        }
        return FreedomIpfsNativeGatewayEvent(
            status: .timeout,
            events: [],
            requestHandle: 0
        )
    }

    func enqueue(_ event: FreedomIpfsNativeGatewayEvent) {
        condition.lock()
        queue.append(event)
        condition.signal()
        condition.unlock()
    }

    func enqueueStatus(_ status: FreedomIpfsNativeGatewayEventStatus) {
        condition.lock()
        queue.append(
            FreedomIpfsNativeGatewayEvent(status: status, events: [], requestHandle: 0)
        )
        condition.signal()
        condition.unlock()
    }

    func shutdown() {
        condition.lock()
        shutdownRequested = true
        condition.broadcast()
        condition.unlock()
    }
}
