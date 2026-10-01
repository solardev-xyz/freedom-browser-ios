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
    /// An `ethereum:` link (EIP-681) a page asked to open. ContentView
    /// turns it into the wallet's Send form and clears it.
    var pendingEthereumURI: URL?
    var records: [TabRecord] = []
    var activeRecordID: UUID?
    /// Tabs closed this run, most recent first (private tabs and empty
    /// tabs excluded — no traces, nothing to reopen).
    private(set) var recentlyClosed = RecentlyClosedTabs()

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let historyStore: HistoryStore
    @ObservationIgnored private let faviconStore: FaviconStore
    @ObservationIgnored private let ensResolver: any ENSResolving
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let wallet: WalletServices
    @ObservationIgnored private let swarm: SwarmServices
    @ObservationIgnored private let radicle: RadicleServices
    @ObservationIgnored private let adblock: AdblockService
    @ObservationIgnored private let ipfs: IPFSNode
    @ObservationIgnored private var liveTabs: [UUID: BrowserTab] = [:]

    init(
        context: ModelContext,
        historyStore: HistoryStore,
        faviconStore: FaviconStore,
        ensResolver: any ENSResolving,
        settings: SettingsStore,
        wallet: WalletServices,
        swarm: SwarmServices,
        radicle: RadicleServices,
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
        self.radicle = radicle
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

    /// Reopen a recently closed tab (long-press on the overview's +): a
    /// new tab in the front, navigated to the closed URL.
    @discardableResult
    func reopen(_ closed: RecentlyClosedTabs.Entry) -> UUID? {
        guard let browserURL = BrowserURL.classify(closed.url) ?? BrowserURL.parse(closed.url.absoluteString) else { return nil }
        recentlyClosed.remove(closed)
        let id = newTab()
        navigateActive(to: browserURL)
        return id
    }

    /// Navigate the active tab, creating one if none is active.
    func navigateActive(to browserURL: BrowserURL) {
        (activeTab ?? ensureActiveTab()).navigate(to: browserURL)
    }

    /// Context-menu "Open in New Tab" / "Open in Background": a new tab
    /// navigated to `url`, activated or left behind the current one.
    func open(_ url: URL, inBackground background: Bool, from opener: BrowserTab?) {
        guard let browserURL = BrowserURL.classify(url) ?? BrowserURL.parse(url.absoluteString) else { return }
        if !background {
            newTab(isPrivate: opener?.isPrivate ?? false)
            navigateActive(to: browserURL)
            return
        }
        // A tab opened from a private tab is private too.
        let record = TabRecord(isPrivate: opener?.isPrivate ?? false)
        context.insert(record)
        // Behind the opener: right after it in the strip.
        let index = opener.flatMap { tab in records.firstIndex { $0.id == tab.recordID } }.map { $0 + 1 } ?? 0
        records.insert(record, at: min(index, records.count))
        save()
        ensureLiveTab(for: record.id).navigate(to: browserURL)
    }

    @discardableResult
    func newTab(isPrivate: Bool = false) -> UUID {
        let record = TabRecord(isPrivate: isPrivate)
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
        let closing = liveTabs[id]
        liveTabs.removeValue(forKey: id)
        if let record = record(for: id) {
            if !record.isPrivate, let url = closing?.displayURL ?? record.url {
                let title = closing.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? record.title ?? ""
                recentlyClosed.push(RecentlyClosedTabs.Entry(url: url, title: title))
            }
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

    private func captureBackground(_ tab: BrowserTab) async {
        guard let record = record(for: tab.recordID) else { return }
        record.url = tab.displayURL
        record.title = tab.title.isEmpty ? nil : tab.title
        save()
        if let snapshot = await tab.snapshotOffscreen() {
            record.lastSnapshot = snapshot
            save()
        }
    }

    private func capture(id: UUID) async {
        guard let tab = liveTabs[id], let record = record(for: id) else { return }
        // Persist the displayURL (ens:// when ENS-originated) so restarts
        // re-resolve the name rather than pin the old content hash.
        record.url = tab.displayURL
        record.title = tab.title.isEmpty ? nil : tab.title
        // A tab on the start page has no web view on screen: no snapshot
        // (a blank one would hide the card's start-page preview).
        if tab.hasNavigated, let snapshot = await tab.snapshot() {
            record.lastSnapshot = snapshot
        } else if !tab.hasNavigated {
            record.lastSnapshot = nil
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
            isPrivate: record(for: id)?.isPrivate ?? false,
            ensResolver: ensResolver,
            settings: settings,
            wallet: wallet,
            swarm: swarm,
            radicle: radicle,
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
    private func adoptPopup(configuration: WKWebViewConfiguration, from opener: BrowserTab?) -> WKWebView {
        // WebKit's popup configuration carries the opener's data store; a
        // popup from a private tab is a private tab.
        let record = TabRecord(isPrivate: opener?.isPrivate ?? false)
        context.insert(record)
        save()
        records.insert(record, at: 0)
        let tab = BrowserTab(
            recordID: record.id,
            isPrivate: record.isPrivate,
            popupConfiguration: configuration,
            ensResolver: ensResolver,
            settings: settings,
            wallet: wallet,
            swarm: swarm,
            radicle: radicle,
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
            // Private tabs leave no local traces: no history entry, no
            // favicon fetch (the cache is on disk), no autocomplete.
            if !tab.isPrivate {
                self.historyStore.record(url: url, title: title)
                self.faviconStore.fetchIfNeeded(for: url, webView: tab.webView)
            }
            // A tab loading in the background (Open in Background) is
            // never captured by activate(); give its switcher card the
            // title, URL and a thumbnail now, or it stays "New Tab".
            if self.activeRecordID != tab.recordID {
                Task { await self.captureBackground(tab) }
            }
        }
        tab.onCreatePopup = { [weak self, weak tab] configuration in
            self?.adoptPopup(configuration: configuration, from: tab)
        }
        tab.onOpenInNewTab = { [weak self, weak tab] url, background in
            guard let self else { return }
            self.open(url, inBackground: background, from: tab)
        }
        tab.onRequestClose = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.close(tab.recordID)
        }
        tab.onEthereumURI = { [weak self] url in
            self?.pendingEthereumURI = url
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
            let fetched = try context.fetch(descriptor)
            // Private tabs are ephemeral by construction: their web data
            // was never on disk, and their records do not outlive the run.
            let stale = fetched.filter(\.isPrivate)
            for record in stale { context.delete(record) }
            if !stale.isEmpty { save() }
            records = fetched.filter { !$0.isPrivate }
        } catch {
            log.error("TabRecord fetch failed: \(String(describing: error), privacy: .public)")
            records = []
        }
    }

    private func save() { context.saveLogging("TabRecord", to: log) }
}
