import SwiftData
import XCTest
@testable import Freedom

@MainActor
final class SwarmFeedStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var store: SwarmFeedStore!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: SwarmFeedRecord.self, configurations: config)
        store = SwarmFeedStore(context: container.mainContext)
    }

    func testEmptyStoreYieldsNoLookupsAndEmptyList() {
        XCTAssertNil(store.lookup(origin: "foo.eth", name: "posts"))
        XCTAssertEqual(store.all(forOrigin: "foo.eth").count, 0)
    }

    func testLookupAndListReturnInsertedRecords() throws {
        // No public writer yet — insert through the context directly.
        let context = container.mainContext
        context.insert(SwarmFeedRecord(
            origin: "foo.eth", name: "posts",
            topic: String(repeating: "a", count: 64),
            owner: "0x1111111111111111111111111111111111111111",
            manifestReference: String(repeating: "b", count: 64)
        ))
        context.insert(SwarmFeedRecord(
            origin: "foo.eth", name: "comments",
            topic: String(repeating: "c", count: 64),
            owner: "0x2222222222222222222222222222222222222222",
            manifestReference: String(repeating: "d", count: 64)
        ))
        context.insert(SwarmFeedRecord(
            origin: "bar.eth", name: "posts",
            topic: String(repeating: "e", count: 64),
            owner: "0x3333333333333333333333333333333333333333",
            manifestReference: String(repeating: "f", count: 64)
        ))
        try context.save()

        let posts = try XCTUnwrap(store.lookup(origin: "foo.eth", name: "posts"))
        XCTAssertEqual(posts.owner, "0x1111111111111111111111111111111111111111")

        let fooFeeds = store.all(forOrigin: "foo.eth")
        XCTAssertEqual(fooFeeds.count, 2)
        // bar.eth's feed must not leak into foo.eth's listing.
        XCTAssertFalse(fooFeeds.contains { $0.origin == "bar.eth" })

        let bar = store.all(forOrigin: "bar.eth")
        XCTAssertEqual(bar.count, 1)
        XCTAssertEqual(bar.first?.name, "posts")
    }

    func testAsListFeedsRowShape() throws {
        let context = container.mainContext
        let manifest = String(repeating: "b", count: 64)
        let record = SwarmFeedRecord(
            origin: "foo.eth", name: "posts",
            topic: String(repeating: "a", count: 64),
            owner: "0x1111111111111111111111111111111111111111",
            manifestReference: manifest,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        context.insert(record)
        try context.save()

        let row = record.asListFeedsRow
        XCTAssertEqual(row["name"] as? String, "posts")
        XCTAssertEqual(row["topic"] as? String, String(repeating: "a", count: 64))
        XCTAssertEqual(row["owner"] as? String, "0x1111111111111111111111111111111111111111")
        XCTAssertEqual(row["manifestReference"] as? String, manifest)
        XCTAssertEqual(row["bzzUrl"] as? String, "bzz://" + manifest)
        XCTAssertEqual(row["createdAt"] as? Int, 1_000)
        XCTAssertTrue(row["lastUpdated"] is NSNull)
        XCTAssertTrue(row["lastReference"] is NSNull)
    }

    func testAsListFeedsRowEncodesPopulatedOptionals() throws {
        let context = container.mainContext
        let record = SwarmFeedRecord(
            origin: "foo.eth", name: "posts",
            topic: String(repeating: "a", count: 64),
            owner: "0x1111111111111111111111111111111111111111",
            manifestReference: String(repeating: "b", count: 64)
        )
        record.lastUpdatedAt = Date(timeIntervalSince1970: 2)
        record.lastReference = String(repeating: "e", count: 64)
        context.insert(record)
        try context.save()

        let row = record.asListFeedsRow
        XCTAssertEqual(row["lastUpdated"] as? Int, 2_000)
        XCTAssertEqual(row["lastReference"] as? String, String(repeating: "e", count: 64))
    }

    func testListIsSortedByCreatedAt() throws {
        let context = container.mainContext
        let early = SwarmFeedRecord(
            origin: "foo.eth", name: "old",
            topic: String(repeating: "a", count: 64),
            owner: "0x1111111111111111111111111111111111111111",
            manifestReference: String(repeating: "b", count: 64),
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let late = SwarmFeedRecord(
            origin: "foo.eth", name: "new",
            topic: String(repeating: "c", count: 64),
            owner: "0x2222222222222222222222222222222222222222",
            manifestReference: String(repeating: "d", count: 64),
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        context.insert(late)  // insert in reverse to confirm sort, not insertion order
        context.insert(early)
        try context.save()

        let names = store.all(forOrigin: "foo.eth").map(\.name)
        XCTAssertEqual(names, ["old", "new"])
    }
}
