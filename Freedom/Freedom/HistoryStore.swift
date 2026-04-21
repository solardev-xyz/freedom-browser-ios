import Foundation
import Observation
import OSLog
import SwiftData

private let log = Logger(subsystem: "com.browser.Freedom", category: "HistoryStore")

@MainActor
@Observable
final class HistoryStore {
    @ObservationIgnored private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Record a visit. If the most-recent entry in the last 5 minutes is for
    /// the same URL, bump its timestamp (and update title) instead of
    /// inserting a duplicate — keeps reload spam and SPA URL bumps from
    /// dominating the history list.
    func record(url: URL, title: String?) {
        let now = Date()
        let dedupWindow: TimeInterval = 5 * 60

        var descriptor = FetchDescriptor<HistoryEntry>(
            sortBy: [SortDescriptor(\.visitedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        if let latest = (try? context.fetch(descriptor))?.first,
           latest.url == url,
           now.timeIntervalSince(latest.visitedAt) < dedupWindow {
            latest.visitedAt = now
            if let newTitle = title, !newTitle.isEmpty, latest.title != newTitle {
                latest.title = newTitle
            }
        } else {
            let normalizedTitle = (title?.isEmpty == false) ? title : nil
            context.insert(HistoryEntry(url: url, title: normalizedTitle))
        }
        save()
    }

    func delete(_ entry: HistoryEntry) {
        context.delete(entry)
        save()
    }

    func clearAll() {
        do {
            try context.delete(model: HistoryEntry.self)
            save()
        } catch {
            log.error("Clear history failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func save() {
        do {
            try context.save()
        } catch {
            log.error("History save failed: \(String(describing: error), privacy: .public)")
        }
    }
}
