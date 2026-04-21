import Foundation
import Observation
import OSLog
import SwiftData

private let log = Logger(subsystem: "com.browser.Freedom", category: "TabStore")

@MainActor
@Observable
final class TabStore {
    var records: [TabRecord] = []
    var activeRecordID: UUID?

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var liveTabs: [UUID: BrowserTab] = [:]

    init(context: ModelContext) {
        self.context = context
        reloadRecords()
    }

    var activeTab: BrowserTab? {
        guard let id = activeRecordID else { return nil }
        return liveTabs[id]
    }

    var activeRecord: TabRecord? {
        activeRecordID.flatMap(record(for:))
    }

    /// Navigate the active tab, creating one if none is active.
    func navigateActive(to browserURL: BrowserURL) {
        (activeTab ?? ensureActiveTab()).navigate(to: browserURL)
    }

    @discardableResult
    func newTab() -> UUID {
        let record = TabRecord()
        context.insert(record)
        save()
        records.insert(record, at: 0)
        activate(record.id)
        return record.id
    }

    func activate(_ id: UUID) {
        guard activeRecordID != id else { return }
        if let outgoing = activeRecordID {
            Task { await capture(id: outgoing) }
        }
        activeRecordID = id
        if let record = record(for: id) {
            record.lastActiveAt = Date()
            save()
        }
        _ = ensureLiveTab(for: id)
    }

    func close(_ id: UUID) {
        liveTabs.removeValue(forKey: id)
        if let record = record(for: id) {
            context.delete(record)
        }
        records.removeAll { $0.id == id }
        save()
        if activeRecordID == id {
            activeRecordID = records.first?.id
            if let newID = activeRecordID {
                _ = ensureLiveTab(for: newID)
            }
        }
    }

    /// Snapshot the currently active tab and persist its state. Called on
    /// scene-phase transition to background.
    func captureActive() async {
        guard let id = activeRecordID else { return }
        await capture(id: id)
    }

    private func capture(id: UUID) async {
        guard let tab = liveTabs[id], let record = record(for: id) else { return }
        record.url = tab.url
        record.title = tab.title.isEmpty ? nil : tab.title
        if let snapshot = await tab.snapshot() {
            record.lastSnapshot = snapshot
        }
        save()
    }

    private func ensureActiveTab() -> BrowserTab {
        if let id = activeRecordID, let tab = liveTabs[id] { return tab }
        let id = activeRecordID ?? newTab()
        return ensureLiveTab(for: id)
    }

    @discardableResult
    private func ensureLiveTab(for id: UUID) -> BrowserTab {
        if let existing = liveTabs[id] { return existing }
        let tab = BrowserTab(recordID: id)
        liveTabs[id] = tab
        if let record = record(for: id),
           let url = record.url,
           let browserURL = BrowserURL.classify(url) {
            tab.navigate(to: browserURL)
        }
        return tab
    }

    private func record(for id: UUID) -> TabRecord? {
        records.first { $0.id == id }
    }

    private func reloadRecords() {
        let descriptor = FetchDescriptor<TabRecord>(
            sortBy: [SortDescriptor(\.lastActiveAt, order: .reverse)]
        )
        do {
            records = try context.fetch(descriptor)
        } catch {
            log.error("TabRecord fetch failed: \(String(describing: error), privacy: .public)")
            records = []
        }
    }

    private func save() {
        do {
            try context.save()
        } catch {
            log.error("TabRecord save failed: \(String(describing: error), privacy: .public)")
        }
    }
}
