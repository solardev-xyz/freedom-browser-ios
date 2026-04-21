import Foundation
import Observation
import OSLog
import SwiftData

private let log = Logger(subsystem: "com.browser.Freedom", category: "BookmarkStore")

@MainActor
@Observable
final class BookmarkStore {
    @ObservationIgnored private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Toggle bookmark status for the URL. Adds if absent, removes if present.
    func toggle(url: URL, title: String?) {
        if let existing = fetchOne(url: url) {
            context.delete(existing)
        } else {
            let normalizedTitle = (title?.isEmpty == false) ? title : nil
            context.insert(Bookmark(url: url, title: normalizedTitle))
        }
        save()
    }

    func delete(_ bookmark: Bookmark) {
        context.delete(bookmark)
        save()
    }

    // #Predicate against URL equality is unreliable under SwiftData on iOS 17.
    // Fetch-all + Swift filter is safe and bookmark counts are small.
    private func fetchOne(url: URL) -> Bookmark? {
        let all = (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
        return all.first { $0.url == url }
    }

    private func save() {
        do {
            try context.save()
        } catch {
            log.error("Bookmark save failed: \(String(describing: error), privacy: .public)")
        }
    }
}
