import XCTest
@testable import Freedom

@MainActor
final class SwarmFeedWriteLockTests: XCTestCase {
    func testSingleCallReturnsResult() async throws {
        let lock = SwarmFeedWriteLock()
        let result = try await lock.withLock(topicHex: "abc") { 42 }
        XCTAssertEqual(result, 42)
    }

    func testRethrowsErrorsFromBody() async {
        struct Boom: Error, Equatable {}
        let lock = SwarmFeedWriteLock()
        do {
            _ = try await lock.withLock(topicHex: "abc") {
                throw Boom()
            }
            XCTFail("Expected throw")
        } catch is Boom {
            // ok
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    /// Two concurrent calls on the same topic observe a serialized
    /// order — the second `fn` doesn't start until the first finishes.
    /// Recorded via timestamps captured inside each body.
    func testSerializesSameTopic() async throws {
        let lock = SwarmFeedWriteLock()
        let recorder = TimingRecorder()
        async let first: Void = lock.withLock(topicHex: "T") {
            await recorder.start("A")
            try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
            await recorder.end("A")
        }
        async let second: Void = lock.withLock(topicHex: "T") {
            await recorder.start("B")
            try await Task.sleep(nanoseconds: 50_000_000)
            await recorder.end("B")
        }
        _ = try await (first, second)
        let timings = await recorder.snapshot()
        XCTAssertNotNil(timings["A"])
        XCTAssertNotNil(timings["B"])
        // B starts AFTER A ends (within @MainActor scheduling tolerance).
        XCTAssertGreaterThanOrEqual(timings["B"]!.start, timings["A"]!.end)
    }

    /// Concurrent calls on *different* topics run in parallel — B's
    /// start does NOT wait for A's end.
    func testParallelizesDifferentTopics() async throws {
        let lock = SwarmFeedWriteLock()
        let recorder = TimingRecorder()
        async let first: Void = lock.withLock(topicHex: "T1") {
            await recorder.start("A")
            try await Task.sleep(nanoseconds: 50_000_000)
            await recorder.end("A")
        }
        async let second: Void = lock.withLock(topicHex: "T2") {
            await recorder.start("B")
            try await Task.sleep(nanoseconds: 50_000_000)
            await recorder.end("B")
        }
        _ = try await (first, second)
        let timings = await recorder.snapshot()
        // B starts before A ends — proves they ran in parallel.
        XCTAssertLessThan(timings["B"]!.start, timings["A"]!.end)
    }

    /// SWIP-aligned: a failed write must not block subsequent writes.
    /// Desktop's `withWriteLock` chains on `.then(fn, fn)` so both
    /// resolve and reject paths advance the queue.
    func testFailureDoesNotPoisonChain() async throws {
        struct Boom: Error {}
        let lock = SwarmFeedWriteLock()
        do {
            _ = try await lock.withLock(topicHex: "T") {
                throw Boom()
            }
            XCTFail("Expected throw")
        } catch {
            // expected
        }
        // Second call on same topic should still proceed.
        let value = try await lock.withLock(topicHex: "T") { "ok" }
        XCTAssertEqual(value, "ok")
    }

    /// Three concurrent writes complete without overlap — verifies the
    /// lock holds across more than two callers without leaking
    /// parallelism. Doesn't pin submission order (Task scheduling on
    /// @MainActor is not strictly FIFO across child tasks); pins the
    /// non-overlap property the lock actually guarantees.
    func testThreeConcurrentWritesDoNotOverlap() async throws {
        let lock = SwarmFeedWriteLock()
        let recorder = TimingRecorder()
        async let a: Void = lock.withLock(topicHex: "T") {
            await recorder.start("A")
            try await Task.sleep(nanoseconds: 30_000_000)
            await recorder.end("A")
        }
        async let b: Void = lock.withLock(topicHex: "T") {
            await recorder.start("B")
            try await Task.sleep(nanoseconds: 30_000_000)
            await recorder.end("B")
        }
        async let c: Void = lock.withLock(topicHex: "T") {
            await recorder.start("C")
            try await Task.sleep(nanoseconds: 30_000_000)
            await recorder.end("C")
        }
        _ = try await (a, b, c)
        let timings = await recorder.snapshot()
        // For each pair, one must end before the other starts.
        for (k1, k2) in [("A", "B"), ("A", "C"), ("B", "C")] {
            let s1 = timings[k1]!, s2 = timings[k2]!
            let nonOverlap = s1.end <= s2.start || s2.end <= s1.start
            XCTAssertTrue(nonOverlap, "\(k1) and \(k2) overlapped: \(s1)/\(s2)")
        }
    }
}

// MARK: - Test recorders

private actor TimingRecorder {
    struct Slot { var start: Date; var end: Date }
    private var entries: [String: Slot] = [:]

    func start(_ key: String) {
        entries[key] = Slot(start: .now, end: .now)
    }

    func end(_ key: String) {
        entries[key]?.end = .now
    }

    func snapshot() -> [String: Slot] { entries }
}
