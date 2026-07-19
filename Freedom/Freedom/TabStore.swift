import Foundation
import IPFSKit
import Observation
import OSLog
import SwiftData
import WebKit

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
    @ObservationIgnored private let adblock: AdblockService
    @ObservationIgnored private let ipfs: IPFSNode
    @ObservationIgnored private var liveTabs: [UUID: BrowserTab] = [:]

    init(
        context: ModelContext,
        historyStore: HistoryStore,
        faviconStore: FaviconStore,
        ensResolver: ENSResolver,
        settings: SettingsStore,
        wallet: WalletServices,
        swarm: SwarmServices,
        adblock: AdblockService,
        ipfs: IPFSNode
    ) {
        self.context = context
        self.historyStore = historyStore
        self.faviconStore = faviconStore
        self.ensResolver = ensResolver
        self.settings = settings
        self.wallet = wallet
        self.swarm = swarm
        self.adblock = adblock
        self.ipfs = ipfs
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
        liveTabs[id]?.teardownSwarmSubscriptions()
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
            swarm: swarm,
            adblock: adblock,
            ipfs: ipfs
        )
        wire(tab)
        liveTabs[id] = tab
        if let record = record(for: id),
           let url = record.url,
           let browserURL = BrowserURL.classify(url) {
            tab.navigate(to: browserURL)
        }
        return tab
    }

    /// Adopt a WebKit-initiated popup (`window.open` / `target="_blank"`
    /// from a page): create a record + live tab whose web view is built
    /// from the configuration WebKit hands us, activate it, and return
    /// the web view for `createWebViewWith`. WebKit performs the popup's
    /// initial load itself — no navigate here.
    private func adoptPopup(configuration: WKWebViewConfiguration) -> WKWebView {
        let record = TabRecord()
        context.insert(record)
        save()
        records.insert(record, at: 0)
        let tab = BrowserTab(
            recordID: record.id,
            popupConfiguration: configuration,
            ensResolver: ensResolver,
            settings: settings,
            wallet: wallet,
            swarm: swarm,
            adblock: adblock,
            ipfs: ipfs
        )
        wire(tab)
        liveTabs[record.id] = tab
        activate(record.id)
        return tab.webView
    }

    /// Wiring common to restored, fresh, and popup tabs.
    private func wire(_ tab: BrowserTab) {
        tab.onNavigationFinish = { [weak self, weak tab] url, title in
            guard let self, let tab else { return }
            // ENS-resolved pages now load as `<codec>://name/` directly,
            // so `url` itself is the canonical ENS form — revisits
            // re-resolve and pick up any content-hash rotation, and the
            // favicon stays tied to the name. The JS extraction still
            // runs against the webview's live page.
            self.historyStore.record(url: url, title: title)
            self.faviconStore.fetchIfNeeded(for: url, webView: tab.webView)
        }
        tab.onCreatePopup = { [weak self] configuration in
            self?.adoptPopup(configuration: configuration)
        }
        tab.onRequestClose = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.close(tab.recordID)
        }
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

    private func save() { context.saveLogging("TabRecord", to: log) }
}
