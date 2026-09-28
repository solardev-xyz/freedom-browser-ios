import Foundation

/// The "reopen closed tab" list: a bounded, most-recent-first stack of
/// what was closed this run (desktop Cmd+Shift+T). Not persisted. Lives
/// behind a long press on the tab overview's + (Safari).
struct RecentlyClosedTabs: Equatable {
    struct Entry: Identifiable, Equatable {
        var id: UUID = UUID()
        let url: URL
        let title: String
        let closedAt: Date = Date()

        var displayTitle: String { title.isEmpty ? (url.host ?? url.absoluteString) : title }
    }

    static let capacity = 10
    private(set) var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }
    var last: Entry? { entries.first }

    mutating func push(_ entry: Entry) {
        // One entry per URL: a page closed twice is one thing to reopen.
        entries.removeAll { $0.url == entry.url }
        entries.insert(entry, at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
    }

    mutating func pop() -> Entry? {
        entries.isEmpty ? nil : entries.removeFirst()
    }

    mutating func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
    }
}
