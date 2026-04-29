import SwiftData
import XCTest
@testable import Freedom

@MainActor
final class SwarmPublishHistoryStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var store: SwarmPublishHistoryStore!

    override func setUp() async throws {
        container = try inMemoryContainer(for: SwarmPublishHistoryRecord.self)
        store = SwarmPublishHistoryStore(context: container.mainContext)
    }

    func testEmptyStoreYieldsNoEntries() {
        XCTAssertEqual(store.entries().count, 0)
    }

    func testRecordInsertsUploadingRow() throws {
        let id = store.record(
            kind: .data, name: "hello.txt", origin: "https://app.eth", bytesSize: 1234
        )
        let row = try XCTUnwrap(store.entry(id: id))
        XCTAssertEqual(row.kind, .data)
        XCTAssertEqual(row.name, "hello.txt")
        XCTAssertEqual(row.origin, "https://app.eth")
        XCTAssertEqual(row.bytesSize, 1234)
        XCTAssertEqual(row.status, .uploading)
        XCTAssertNil(row.reference)
        XCTAssertNil(row.completedAt)
        XCTAssertNil(row.errorMessage)
    }

    func testCompletePopulatesReferenceAndFinalStatus() throws {
        let id = store.record(kind: .files, name: "site", origin: "https://app.eth")
        let ref = String(repeating: "a", count: 64)
        store.complete(id: id, reference: ref, tagUid: 42, batchId: "batch-xyz")
        let row = try XCTUnwrap(store.entry(id: id))
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.reference, ref)
        XCTAssertEqual(row.tagUid, 42)
        XCTAssertEqual(row.batchId, "batch-xyz")
        XCTAssertEqual(row.bzzUrl, "bzz://" + ref)
        XCTAssertNotNil(row.completedAt)
        XCTAssertNil(row.errorMessage)
    }

    func testFailRecordsErrorMessage() throws {
        let id = store.record(kind: .feedEntry, name: "posts", origin: "https://app.eth")
        store.fail(id: id, errorMessage: "no usable stamps")
        let row = try XCTUnwrap(store.entry(id: id))
        XCTAssertEqual(row.status, .failed)
        XCTAssertEqual(row.errorMessage, "no usable stamps")
        XCTAssertNotNil(row.completedAt)
        XCTAssertNil(row.reference)
    }

    func testCompleteOnUnknownIdIsNoOp() {
        store.complete(id: UUID(), reference: String(repeating: "a", count: 64))
        XCTAssertEqual(store.entries().count, 0)
    }

    func testFailOnUnknownIdIsNoOp() {
        store.fail(id: UUID(), errorMessage: "x")
        XCTAssertEqual(store.entries().count, 0)
    }

    func testEntriesSortedNewestFirst() throws {
        let context = container.mainContext
        let oldRow = SwarmPublishHistoryRecord(
            kind: .data, name: "old", origin: "https://a.eth",
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let newRow = SwarmPublishHistoryRecord(
            kind: .data, name: "new", origin: "https://a.eth",
            startedAt: Date(timeIntervalSince1970: 200)
        )
        // Insert in reverse to confirm sort, not insertion order.
        context.insert(oldRow)
        context.insert(newRow)
        try context.save()

        let names = store.entries().map(\.name)
        XCTAssertEqual(names, ["new", "old"])
    }

    func testSweepOrphansFlipsUploadingToFailed() throws {
        let interrupted = store.record(kind: .data, name: "a", origin: "https://a.eth")
        let alreadyDone = store.record(kind: .data, name: "b", origin: "https://a.eth")
        store.complete(id: alreadyDone, reference: String(repeating: "b", count: 64))
        let alreadyFailed = store.record(kind: .data, name: "c", origin: "https://a.eth")
        store.fail(id: alreadyFailed, errorMessage: "x")

        store.sweepOrphans()

        let interruptedRow = try XCTUnwrap(store.entry(id: interrupted))
        XCTAssertEqual(interruptedRow.status, .failed)
        XCTAssertEqual(interruptedRow.errorMessage, "Interrupted by app exit")
        XCTAssertNotNil(interruptedRow.completedAt)

        // Settled rows are untouched.
        XCTAssertEqual(try XCTUnwrap(store.entry(id: alreadyDone)).status, .completed)
        XCTAssertEqual(try XCTUnwrap(store.entry(id: alreadyFailed)).errorMessage, "x")
    }

    func testSweepOrphansOnEmptyStoreIsNoOp() {
        store.sweepOrphans()
        XCTAssertEqual(store.entries().count, 0)
    }

    func testDeleteRemovesSingleRow() {
        let keep = store.record(kind: .data, name: "keep", origin: "https://a.eth")
        let drop = store.record(kind: .data, name: "drop", origin: "https://a.eth")
        store.delete(id: drop)
        let names = store.entries().map(\.name)
        XCTAssertEqual(names, ["keep"])
        XCTAssertNotNil(store.entry(id: keep))
        XCTAssertNil(store.entry(id: drop))
    }

    func testClearAllRemovesEverything() {
        _ = store.record(kind: .data, name: "a", origin: "https://a.eth")
        _ = store.record(kind: .files, name: "b", origin: "https://a.eth")
        _ = store.record(kind: .feedCreate, name: "c", origin: "https://a.eth")
        store.clearAll()
        XCTAssertEqual(store.entries().count, 0)
    }

    func testBzzUrlNilUntilReferenceSet() {
        let id = store.record(kind: .data, name: "x", origin: "https://a.eth")
        let row = store.entry(id: id)
        XCTAssertNil(row?.bzzUrl)
    }
}
