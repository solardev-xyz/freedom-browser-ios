import SwiftData
import XCTest
@testable import Freedom

@MainActor
final class SwarmFeedStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var store: SwarmFeedStore!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: SwarmFeedRecord.self, SwarmFeedIdentity.self,
            configurations: config
        )
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

    // MARK: - Writers (WP6.1)

    func testUpsertCreatesAndIsIdempotent() {
        let topic = String(repeating: "a", count: 64)
        let manifest = String(repeating: "b", count: 64)
        let owner = "0x1111111111111111111111111111111111111111"
        store.upsert(origin: "foo.eth", name: "posts",
                     topic: topic, owner: owner, manifestReference: manifest)
        store.upsert(origin: "foo.eth", name: "posts",
                     topic: topic, owner: owner, manifestReference: manifest)
        // SWIP "createFeed is idempotent" — re-creating the same
        // (origin, name) must not produce a duplicate row.
        XCTAssertEqual(store.all(forOrigin: "foo.eth").count, 1)
    }

    func testUpdateReferencePopulatesPointerFields() throws {
        store.upsert(
            origin: "foo.eth", name: "posts",
            topic: String(repeating: "a", count: 64),
            owner: "0x1111111111111111111111111111111111111111",
            manifestReference: String(repeating: "b", count: 64)
        )
        let newRef = String(repeating: "c", count: 64)
        store.updateReference(origin: "foo.eth", name: "posts", reference: newRef)
        let record = try XCTUnwrap(store.lookup(origin: "foo.eth", name: "posts"))
        XCTAssertEqual(record.lastReference, newRef)
        XCTAssertNotNil(record.lastUpdatedAt)
    }

    func testUpdateReferenceOnUnknownFeedIsNoOp() {
        store.updateReference(
            origin: "foo.eth", name: "ghost",
            reference: String(repeating: "c", count: 64)
        )
        // No row created, no crash.
        XCTAssertEqual(store.all(forOrigin: "foo.eth").count, 0)
    }

    // MARK: - Feed identity

    func testFeedIdentityRoundtrip() throws {
        XCTAssertNil(store.feedIdentity(origin: "foo.eth"))
        store.setFeedIdentity(
            origin: "foo.eth", identityMode: .appScoped, publisherKeyIndex: 0
        )
        let identity = try XCTUnwrap(store.feedIdentity(origin: "foo.eth"))
        XCTAssertEqual(identity.identityMode, .appScoped)
        XCTAssertEqual(identity.publisherKeyIndex, 0)
    }

    func testFeedIdentityIsImmutableAfterFirstSet() throws {
        store.setFeedIdentity(
            origin: "foo.eth", identityMode: .appScoped, publisherKeyIndex: 0
        )
        // Per SWIP §8.6, identity mode is immutable per origin once
        // chosen — flipping it would orphan existing feeds. Subsequent
        // calls must be no-ops.
        store.setFeedIdentity(
            origin: "foo.eth", identityMode: .beeWallet, publisherKeyIndex: nil
        )
        let identity = try XCTUnwrap(store.feedIdentity(origin: "foo.eth"))
        XCTAssertEqual(identity.identityMode, .appScoped)
        XCTAssertEqual(identity.publisherKeyIndex, 0)
    }

    func testFeedIdentityScopedPerOrigin() throws {
        store.setFeedIdentity(
            origin: "foo.eth", identityMode: .appScoped, publisherKeyIndex: 0
        )
        store.setFeedIdentity(
            origin: "bar.eth", identityMode: .beeWallet, publisherKeyIndex: nil
        )
        XCTAssertEqual(store.feedIdentity(origin: "foo.eth")?.identityMode, .appScoped)
        XCTAssertEqual(store.feedIdentity(origin: "bar.eth")?.identityMode, .beeWallet)
        XCTAssertNil(store.feedIdentity(origin: "bar.eth")?.publisherKeyIndex)
    }

    // MARK: - nextPublisherKeyIndex

    func testNextPublisherKeyIndexEmptyStoreYieldsZero() {
        XCTAssertEqual(store.nextPublisherKeyIndex(), 0)
    }

    func testNextPublisherKeyIndexMonotonicAcrossAppScopedOrigins() {
        XCTAssertEqual(store.nextPublisherKeyIndex(), 0)
        store.setFeedIdentity(origin: "a.eth", identityMode: .appScoped,
                              publisherKeyIndex: 0)
        XCTAssertEqual(store.nextPublisherKeyIndex(), 1)
        store.setFeedIdentity(origin: "b.eth", identityMode: .appScoped,
                              publisherKeyIndex: 1)
        XCTAssertEqual(store.nextPublisherKeyIndex(), 2)
        store.setFeedIdentity(origin: "c.eth", identityMode: .appScoped,
                              publisherKeyIndex: 2)
        XCTAssertEqual(store.nextPublisherKeyIndex(), 3)
    }

    func testNextPublisherKeyIndexSkipsBeeWalletOrigins() {
        // bee-wallet rows have publisherKeyIndex == nil and must not
        // perturb the allocator's max+1.
        store.setFeedIdentity(origin: "wallet.eth", identityMode: .beeWallet,
                              publisherKeyIndex: nil)
        XCTAssertEqual(store.nextPublisherKeyIndex(), 0)
        store.setFeedIdentity(origin: "a.eth", identityMode: .appScoped,
                              publisherKeyIndex: 0)
        XCTAssertEqual(store.nextPublisherKeyIndex(), 1)
        store.setFeedIdentity(origin: "wallet2.eth", identityMode: .beeWallet,
                              publisherKeyIndex: nil)
        XCTAssertEqual(store.nextPublisherKeyIndex(), 1)
    }

    func testNextPublisherKeyIndexRespectsExistingMaxIndex() {
        // Multi-origin user re-launching the app continues from the
        // existing max, not restart at 0.
        for i in 0...5 {
            store.setFeedIdentity(origin: "origin\(i).eth",
                                  identityMode: .appScoped,
                                  publisherKeyIndex: i)
        }
        XCTAssertEqual(store.nextPublisherKeyIndex(), 6)
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
