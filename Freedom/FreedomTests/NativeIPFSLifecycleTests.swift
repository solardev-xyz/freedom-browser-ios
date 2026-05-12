import XCTest
import WebKit
@testable import IPFSKit
@testable import Freedom

/// Lifecycle invariants for the native FFI sink (`NativePending`).
/// These guard the bug class that crashes WebKit at runtime: extra
/// `didFinish`/`didFailWithError` calls after a task has already
/// terminated. Driven entirely through fakes — no Rust reader or real
/// `WKURLSchemeTask` required.
@MainActor
final class NativeIPFSLifecycleTests: XCTestCase {
    private let url = URL(string: "ipfs://bafybeiaql2jo3fu5b7c4lmpoi5drh5sam7yt652shwdgwbky4o7uw33u2u/")!

    /// Leak per-test fixtures into a static array so they don't deinit
    /// when the test method returns. Mirrors the workaround in
    /// `NativeIPFSCorpusTests` for the Swift
    /// `swift_task_deinitOnExecutorMainActorBackDeploy` crash that fires
    /// when @MainActor classes get released through the dispatched-main
    /// path. Even on the iOS 18 deployment target the runtime still
    /// trips this on the test deinit ordering — XCTest's per-test
    /// teardown crashes with a malloc double-free before XCTest can
    /// record results, so the tests appear to "pass with 0 executed".
    nonisolated(unsafe) private static var leakedDependencies: [AnyObject] = []

    func testHappyPathDeliversResponseThenFinish() {
        let (task, handle, owner, pending) = makePending()
        handle.enqueueResponseJSON(Self.responseJSON(state: .streaming, status: 200))
        handle.enqueueRead(.bytes(Data("hello".utf8)))
        handle.enqueueRead(.status(.end))

        pending.nativeRequestReceivedEvent(makeEvent([.responseReady]))
        pending.nativeRequestReceivedEvent(makeEvent([.bodyReady, .end]))
        waitForMain(until: { task.finishCount == 1 })

        XCTAssertEqual(task.responses.count, 1)
        XCTAssertEqual((task.responses.first as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(task.dataChunks.map { String(decoding: $0, as: UTF8.self) }, ["hello"])
        XCTAssertEqual(task.finishCount, 1)
        XCTAssertTrue(task.failErrors.isEmpty)
        XCTAssertEqual(handle.freeCount, 1)
        XCTAssertFalse(owner.activeHandles.contains(handle.id), "Owner should be cleared on terminal")
    }

    /// The single most important regression guard: WebKit aborts the
    /// app if `didFailWithError` lands after a successful `didFinish`.
    /// A late `.failed` event from the dispatcher must be a no-op.
    func testStaleFailedAfterEndIsIgnored() {
        let (task, handle, _, pending) = makePending()
        handle.enqueueResponseJSON(Self.responseJSON(state: .streaming, status: 200))
        handle.enqueueRead(.status(.end))

        pending.nativeRequestReceivedEvent(makeEvent([.responseReady]))
        pending.nativeRequestReceivedEvent(makeEvent([.bodyReady, .end]))
        waitForMain(until: { task.finishCount == 1 })

        pending.nativeRequestReceivedEvent(makeEvent([.failed]))
        waitForMain(briefly: 0.05)

        XCTAssertEqual(task.finishCount, 1, "Late .failed must not trigger an additional terminal")
        XCTAssertTrue(task.failErrors.isEmpty, "No didFailWithError after a clean didFinish")
        XCTAssertEqual(handle.freeCount, 1, "handle.free() must not double-fire")
    }

    /// Reaching `.end` twice (dispatcher quirk or duplicate event) must
    /// not call `didFinish` twice. WK crashes on the second call.
    func testDuplicateEndDoesNotDoubleFinish() {
        let (task, handle, _, pending) = makePending()
        handle.enqueueResponseJSON(Self.responseJSON(state: .streaming, status: 200))
        handle.enqueueRead(.status(.end))
        // Second .end queued in case drainBody is re-entered.
        handle.enqueueRead(.status(.end))

        pending.nativeRequestReceivedEvent(makeEvent([.responseReady]))
        pending.nativeRequestReceivedEvent(makeEvent([.bodyReady, .end]))
        waitForMain(until: { task.finishCount == 1 })
        pending.nativeRequestReceivedEvent(makeEvent([.bodyReady, .end]))
        waitForMain(briefly: 0.05)

        XCTAssertEqual(task.finishCount, 1)
        XCTAssertEqual(handle.freeCount, 1)
    }

    /// After the owner calls `markTerminated()` (which happens
    /// synchronously inside `webView(_:stop:)`), no further dispatcher
    /// event should reach the scheme task or the FFI.
    func testEventAfterMarkTerminatedIsSilenced() {
        let (task, handle, _, pending) = makePending()
        handle.enqueueResponseJSON(Self.responseJSON(state: .streaming, status: 200))

        pending.nativeRequestReceivedEvent(makeEvent([.responseReady]))
        waitForMain(until: { task.responses.count == 1 })

        // Owner cancels (this is what `cancelActiveNative(matching:)`
        // does before calling handle.cancel/free itself).
        pending.markTerminated()

        // A late event after termination should be silently dropped.
        pending.nativeRequestReceivedEvent(makeEvent([.bodyReady, .end]))
        waitForMain(briefly: 0.1)

        XCTAssertEqual(task.dataChunks.count, 0, "No body should be drained after termination")
        XCTAssertEqual(task.finishCount, 0, "No didFinish after termination")
        XCTAssertTrue(task.failErrors.isEmpty, "No didFailWithError after termination")
        // `markTerminated` does NOT itself free the handle — that's the
        // owner's job (cancel+free in `cancelActiveNative`). The sink
        // should not race the owner here.
        XCTAssertEqual(handle.freeCount, 0)
    }

    /// `NativeGatewayDispatcher.stop()` synthesizes a
    /// `[.cancelled, .handleFreed]` event for every registered sink so
    /// they can terminate cleanly. The sink must translate that into
    /// one `didFailWithError(URLError(.cancelled))`, free the handle
    /// exactly once, and remove itself from the owner.
    func testGatewayStoppedSyntheticEventTerminatesWithCancelled() {
        let (task, handle, owner, pending) = makePending()

        let synthetic = FreedomIpfsNativeGatewayEvent(
            status: .gatewayStopped,
            events: [.cancelled, .handleFreed],
            requestHandle: handle.id
        )
        pending.nativeRequestReceivedEvent(synthetic)
        waitForMain(until: { !task.failErrors.isEmpty })

        XCTAssertEqual(task.finishCount, 0)
        XCTAssertEqual(task.failErrors.count, 1)
        if let urlError = task.failErrors.first as? URLError {
            XCTAssertEqual(urlError.code, .cancelled)
        } else {
            XCTFail("Expected URLError(.cancelled), got \(String(describing: task.failErrors.first))")
        }
        XCTAssertEqual(handle.freeCount, 1)
        XCTAssertFalse(owner.activeHandles.contains(handle.id))
    }

    /// Defense in depth: even though `NativeGatewayDispatcher` routes
    /// by registered handle id, a mis-routed event reaching the sink
    /// must not free `self.handle` or fire WK callbacks for the wrong
    /// request.
    func testEventForWrongHandleIsIgnored() {
        let (task, handle, _, pending) = makePending()
        handle.enqueueResponseJSON(Self.responseJSON(state: .streaming, status: 200))

        pending.nativeRequestReceivedEvent(makeEvent([.responseReady], handle: 999))
        pending.nativeRequestReceivedEvent(makeEvent([.bodyReady, .end], handle: 999))
        pending.nativeRequestReceivedEvent(makeEvent([.failed], handle: 999))
        waitForMain(briefly: 0.1)

        XCTAssertEqual(task.responses.count, 0)
        XCTAssertEqual(task.dataChunks.count, 0)
        XCTAssertEqual(task.finishCount, 0)
        XCTAssertTrue(task.failErrors.isEmpty)
        XCTAssertEqual(handle.freeCount, 0)
    }

    /// Rust may emit terminal metadata with `state: "cancelled"` when
    /// the request was cancelled cleanly. The sink must surface that as
    /// `URLError(.cancelled)` so WebKit's error-page UX recognises it
    /// as a user-initiated cancel — not as a generic
    /// `FreedomIPFSNativeGateway` error page.
    func testCancelledMetadataMapsToURLErrorCancelled() {
        let (task, handle, _, pending) = makePending()
        handle.enqueueResponseJSON(#"{"state":"cancelled","error":{"code":"cancelled","message":"client cancelled"}}"#)

        pending.nativeRequestReceivedEvent(makeEvent([.failed]))
        waitForMain(until: { !task.failErrors.isEmpty })

        XCTAssertEqual(task.failErrors.count, 1)
        if let urlError = task.failErrors.first as? URLError {
            XCTAssertEqual(urlError.code, .cancelled)
        } else {
            XCTFail("Expected URLError(.cancelled), got \(String(describing: task.failErrors.first))")
        }
        XCTAssertEqual(handle.freeCount, 1)
    }

    /// Race window: the owner removes the entry from `activeNative`
    /// between the `DispatchQueue.main.async` enqueue and its
    /// execution. The deliverOnMain containment check must drop the
    /// callback.
    func testDeliveryAfterOwnerRemovedIsDropped() {
        let (task, handle, owner, pending) = makePending()
        handle.enqueueResponseJSON(Self.responseJSON(state: .streaming, status: 200))

        pending.nativeRequestReceivedEvent(makeEvent([.responseReady]))
        // Simulate `webView(_:stop:)` racing in before the main-queue
        // hop runs: owner removes the entry, but doesn't markTerminated
        // (markTerminated happens after, in production).
        owner.activeHandles.remove(handle.id)
        waitForMain(briefly: 0.1)

        XCTAssertEqual(task.responses.count, 0, "Containment check must drop the response delivery")
        XCTAssertEqual(task.finishCount, 0)
        XCTAssertTrue(task.failErrors.isEmpty)
    }

    // MARK: - Helpers

    private func makePending() -> (FakeURLSchemeTask, FakeNativeGatewayHandle, StubNativePendingOwner, NativePending) {
        let task = FakeURLSchemeTask(url: url)
        let handle = FakeNativeGatewayHandle(id: 42)
        let owner = StubNativePendingOwner()
        owner.activeHandles.insert(handle.id)
        let pending = NativePending(
            schemeTask: task,
            originalURL: url,
            handle: handle,
            owner: owner
        )
        Self.leakedDependencies.append(contentsOf: [task, handle, owner, pending] as [AnyObject])
        return (task, handle, owner, pending)
    }

    private func makeEvent(_ flags: FreedomIpfsNativeGatewayEventFlags, handle: UInt64 = 42) -> FreedomIpfsNativeGatewayEvent {
        FreedomIpfsNativeGatewayEvent(status: .ok, events: flags, requestHandle: handle)
    }

    /// Drain the main runloop until `predicate` is true or `timeout`
    /// fires. We can't use XCTestExpectation cleanly because we're
    /// polling state that mutates on async main-queue hops with no
    /// natural fulfillment point.
    private func waitForMain(until predicate: @MainActor () -> Bool, timeout: TimeInterval = 1.0) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if predicate() { return }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        XCTFail("Predicate did not become true within \(timeout)s")
    }

    /// Drain queued main-queue work without an associated wait condition.
    /// Used to give a "should not happen" assertion time to be falsified.
    private func waitForMain(briefly seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private static func responseJSON(state: IpfsSchemeHandler.NativeResponseMetadata.State, status: Int) -> String {
        """
        {"state":"\(state.rawValue)","status":\(status),"headers":[{"name":"Content-Type","value":"text/html"}]}
        """
    }
}

// MARK: - Fakes

/// `WKURLSchemeTask` is an `@objc` protocol. Fake stores call records so
/// tests can assert on the sequence of WK callbacks the SUT made. Does
/// NOT crash on duplicate `didFinish`/`didFailWithError` (the real WK
/// task does — and that's exactly the bug class these tests guard).
@MainActor
private final class FakeURLSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest

    var responses: [URLResponse] = []
    var dataChunks: [Data] = []
    var finishCount = 0
    var failErrors: [any Error] = []

    init(url: URL) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        self.request = req
        super.init()
    }

    func didReceive(_ response: URLResponse) {
        responses.append(response)
    }

    func didReceive(_ data: Data) {
        dataChunks.append(data)
    }

    func didFinish() {
        finishCount += 1
    }

    func didFailWithError(_ error: any Error) {
        failErrors.append(error)
    }
}

/// Scriptable fake for `NativeGatewayHandleProtocol`. Thread-safe so
/// production code paths that call FFI from a worker thread also work
/// in tests where we call them from main.
private final class FakeNativeGatewayHandle: NativeGatewayHandleProtocol, @unchecked Sendable {
    let id: UInt64

    enum ScriptedRead {
        case status(FreedomIpfsNativeGatewayReadStatus)
        case bytes(Data)
    }

    private let lock = NSLock()
    private var responseJSONQueue: [String] = []
    private var readQueue: [ScriptedRead] = []
    private(set) var cancelCount = 0
    private(set) var freeCount = 0

    init(id: UInt64) {
        self.id = id
    }

    func enqueueResponseJSON(_ json: String) {
        lock.lock(); defer { lock.unlock() }
        responseJSONQueue.append(json)
    }

    func enqueueRead(_ result: ScriptedRead) {
        lock.lock(); defer { lock.unlock() }
        readQueue.append(result)
    }

    func responseJSON(timeoutMilliseconds: UInt64) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard !responseJSONQueue.isEmpty else {
            // Mirror Rust's "no response yet" — pending state JSON.
            return #"{"state":"pending"}"#
        }
        return responseJSONQueue.removeFirst()
    }

    func read(
        into buffer: UnsafeMutableRawBufferPointer,
        timeoutMilliseconds: UInt64
    ) throws -> FreedomIpfsNativeGatewayReadResult {
        lock.lock()
        let item: ScriptedRead = readQueue.isEmpty ? .status(.pending) : readQueue.removeFirst()
        lock.unlock()
        switch item {
        case .status(let status):
            return FreedomIpfsNativeGatewayReadResult(status: status, bytesRead: 0)
        case .bytes(let data):
            let count = min(data.count, buffer.count)
            data.withUnsafeBytes { src in
                if let base = src.baseAddress, count > 0 {
                    buffer.copyMemory(from: UnsafeRawBufferPointer(start: base, count: count))
                }
            }
            return FreedomIpfsNativeGatewayReadResult(status: .bytes, bytesRead: count)
        }
    }

    @discardableResult
    func cancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        cancelCount += 1
        return true
    }

    @discardableResult
    func free() -> Bool {
        lock.lock(); defer { lock.unlock() }
        freeCount += 1
        return true
    }
}

/// Stub for `NativePendingOwner` that records dict ops without needing
/// a real `IpfsSchemeHandler` (which would need a real `IPFSNode`).
@MainActor
private final class StubNativePendingOwner: NativePendingOwner {
    var activeHandles: Set<UInt64> = []
    var removeCalls: [UInt64] = []

    func nativePendingClaimDelivery(handleID: UInt64) -> Bool {
        activeHandles.contains(handleID)
    }

    func nativePendingRemove(handleID: UInt64) -> Bool {
        let removed = activeHandles.remove(handleID) != nil
        if removed { removeCalls.append(handleID) }
        return removed
    }
}
