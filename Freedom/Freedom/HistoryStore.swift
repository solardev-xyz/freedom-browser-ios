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

    func record(url: URL, title: String?) {
        let normalizedTitle = (title?.isEmpty == false) ? title : nil
        context.insert(HistoryEntry(url: url, title: normalizedTitle))
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
