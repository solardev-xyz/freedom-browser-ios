import XCTest
@testable import Freedom

final class RecentlyClosedTabsTests: XCTestCase {
    func testBoundedDedupedAndMostRecentFirst() {
        var closed = RecentlyClosedTabs()
        XCTAssertTrue(closed.isEmpty)
        for i in 0..<12 {
            closed.push(RecentlyClosedTabs.Entry(url: URL(string: "https://x.example/\(i)")!, title: "Page \(i)"))
        }
        XCTAssertEqual(closed.entries.count, RecentlyClosedTabs.capacity)
        XCTAssertEqual(closed.last?.title, "Page 11")
        XCTAssertEqual(closed.entries.last?.title, "Page 2", "oldest dropped")
        closed.push(RecentlyClosedTabs.Entry(url: URL(string: "https://x.example/5")!, title: "Page 5 again"))
        XCTAssertEqual(closed.entries.filter { $0.url.path == "/5" }.count, 1, "one entry per URL")
        XCTAssertEqual(closed.last?.title, "Page 5 again")
        XCTAssertEqual(closed.pop()?.title, "Page 5 again")
        XCTAssertEqual(closed.entries.count, RecentlyClosedTabs.capacity - 1)
        let entry = closed.entries[2]
        closed.remove(entry)
        XCTAssertFalse(closed.entries.contains(entry))
        XCTAssertEqual(RecentlyClosedTabs.Entry(url: URL(string: "https://host.example/p")!, title: "").displayTitle, "host.example")
    }
}
