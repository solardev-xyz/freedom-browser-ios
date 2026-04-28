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
    @ObservationIgnored private let historyStore: HistoryStore
    @ObservationIgnored private let faviconStore: FaviconStore
    @ObservationIgnored private let ensResolver: ENSResolver
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let wallet: WalletServices
    @ObservationIgnored private let swarm: SwarmServices
    @ObservationIgnored private var liveTabs: [UUID: BrowserTab] = [:]

    init(
        context: ModelContext,
        historyStore: HistoryStore,
        faviconStore: FaviconStore,
        ensResolver: ENSResolver,
        settings: SettingsStore,
        wallet: WalletServices,
        swarm: SwarmServices
    ) {
        self.context = context
        self.historyStore = historyStore
        self.faviconStore = faviconStore
        self.ensResolver = ensResolver
        self.settings = settings
        self.wallet = wallet
        self.swarm = swarm
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
        // Cancel any in-flight ENS resolution or page load before dropping
        // the reference — otherwise the Task retains the tab + webview past
        // removal here and may call webView.load(...) on a detached view.
        // `resolvePendingApproval(.denied)` un-parks any CheckedContinuation
        // the bridge is waiting on, so closing a tab mid-approval doesn't
        // leak the awaiting task.
        liveTabs[id]?.stop()
        liveTabs[id]?.resolvePendingApproval(.denied)
        liveTabs[id]?.resolvePendingSwarmApproval(.denied)
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
        // Persist the displayURL (ens:// when ENS-originated) so restarts
        // re-resolve the name rather than pin the old content hash.
        record.url = tab.displayURL
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
        let tab = BrowserTab(
            recordID: id,
            ensResolver: ensResolver,
            settings: settings,
            wallet: wallet,
            swarm: swarm
        )
        tab.onNavigationFinish = { [weak self, weak tab] url, title in
            guard let self, let tab else { return }
            // Key history AND favicons on the ens:// form when we navigated
            // via ENS — revisits re-resolve (and pick up any content-hash
            // rotation by the record owner) while the favicon stays tied
            // to the name, not to whichever bzz hash happens to be current.
            // The JS extraction still runs against the webview's live page
            // (the resolved bzz content), only the storage key changes.
            let displayURL = tab.ensURL ?? url
            self.historyStore.record(url: displayURL, title: title)
            self.faviconStore.fetchIfNeeded(for: displayURL, webView: tab.webView)
        }
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
