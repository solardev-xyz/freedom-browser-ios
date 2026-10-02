import SwiftData
import XCTest
@testable import Freedom

/// Bookmarks: ordering, rename, re-address, reorder (desktop "named
/// bookmarks" + "reorder by drag").
@MainActor
final class BookmarkStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var store: BookmarkStore!

    override func setUp() async throws {
        container = try inMemoryContainer(for: Bookmark.self)
        store = BookmarkStore(context: container.mainContext)
    }

    private func add(_ raw: String, title: String? = nil) {
        store.toggle(url: URL(string: raw)!, title: title)
    }

    func testNewBookmarksGoOnTopAndLegacyRowsKeepNewestFirst() throws {
        // Two pre-migration rows: sortIndex 0, ordered by createdAt.
        let older = Bookmark(url: URL(string: "https://old.example")!, createdAt: Date(timeIntervalSince1970: 1))
        let newer = Bookmark(url: URL(string: "https://new.example")!, createdAt: Date(timeIntervalSince1970: 2))
        container.mainContext.insert(older)
        container.mainContext.insert(newer)
        add("https://added.example")
        XCTAssertEqual(store.ordered().map(\.url.host), ["added.example", "new.example", "old.example"])
    }

    func testMoveRenumbersEveryRow() throws {
        add("https://a.example"); add("https://b.example"); add("https://c.example")
        XCTAssertEqual(store.ordered().map(\.url.host), ["c.example", "b.example", "a.example"])
        store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        let rows = store.ordered()
        XCTAssertEqual(rows.map(\.url.host), ["a.example", "c.example", "b.example"])
        XCTAssertEqual(rows.map(\.sortIndex), [0, 1, 2])
        // A later addition still lands on top.
        add("https://d.example")
        XCTAssertEqual(store.ordered().map(\.url.host).first, "d.example")
    }

    func testUpdateRenamesAndReaddresses() throws {
        add("https://a.example", title: "A")
        let bookmark = store.ordered()[0]
        XCTAssertTrue(store.update(bookmark, title: "  Vitalik  ", address: "vitalik.eth"))
        XCTAssertEqual(bookmark.title, "Vitalik")
        XCTAssertEqual(bookmark.url.absoluteString, "ens://vitalik.eth")
        XCTAssertEqual(bookmark.host, "vitalik.eth")
        XCTAssertTrue(store.update(bookmark, title: "", address: "example.com/docs"))
        XCTAssertNil(bookmark.title)
        XCTAssertEqual(bookmark.displayTitle, "example.com")
        XCTAssertEqual(bookmark.url.absoluteString, "https://example.com/docs")
    }

    func testUpdateRefusesAnAddressTheBrowserCannotOpen() throws {
        add("https://a.example", title: "A")
        let bookmark = store.ordered()[0]
        XCTAssertFalse(store.update(bookmark, title: "B", address: "not a url at all"))
        XCTAssertEqual(bookmark.title, "A")
        XCTAssertEqual(bookmark.url.host, "a.example")
        XCTAssertNil(BookmarkStore.url(fromAddress: ""))
    }
}
