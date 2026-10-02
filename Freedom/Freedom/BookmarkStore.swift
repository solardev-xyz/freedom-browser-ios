import Foundation
import Observation
import OSLog
import SwiftData
import SwiftUI

private let log = Logger(subsystem: "com.browser.Freedom", category: "BookmarkStore")

@MainActor
@Observable
final class BookmarkStore {
    @ObservationIgnored private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Toggle bookmark status for the URL. Adds if absent (at the top of
    /// the list), removes if present.
    func toggle(url: URL, title: String?) {
        if let existing = fetchOne(url: url) {
            context.delete(existing)
        } else {
            let normalizedTitle = (title?.isEmpty == false) ? title : nil
            let first = ordered().first?.sortIndex ?? 0
            context.insert(Bookmark(url: url, title: normalizedTitle, sortIndex: first - 1))
        }
        save()
    }

    func delete(_ bookmark: Bookmark) {
        context.delete(bookmark)
        save()
    }

    /// Rename and/or re-address a bookmark (desktop "named bookmarks").
    /// The address must be something the browser can open; returns
    /// false (and changes nothing) otherwise.
    @discardableResult
    func update(_ bookmark: Bookmark, title: String?, address: String) -> Bool {
        guard let url = Self.url(fromAddress: address) else { return false }
        bookmark.update(title: title, url: url)
        save()
        return true
    }

    /// Move rows as `List.onMove` reports, then renumber so the stored
    /// order is explicit for every bookmark (desktop "reorder by drag").
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var rows = ordered()
        rows.move(fromOffsets: source, toOffset: destination)
        for (index, bookmark) in rows.enumerated() where bookmark.sortIndex != index {
            bookmark.sortIndex = index
        }
        save()
    }

    /// Bookmarks in display order (`Bookmark.order`).
    func ordered() -> [Bookmark] {
        (try? context.fetch(FetchDescriptor<Bookmark>(sortBy: Bookmark.order))) ?? []
    }

    /// What a typed address becomes: the same rules as the address bar
    /// (`BrowserURL.parse`), minus web search. A bare name stays a name
    /// (`ens://name`), a hostname gets `https://`.
    static func url(fromAddress address: String) -> URL? {
        BrowserURL.parse(address)?.url
    }

    // #Predicate against URL equality is unreliable under SwiftData on iOS 17.
    // Fetch-all + Swift filter is safe and bookmark counts are small.
    private func fetchOne(url: URL) -> Bookmark? {
        let all = (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
        return all.first { $0.url == url }
    }

    private func save() { context.saveLogging("Bookmark", to: log) }
}
