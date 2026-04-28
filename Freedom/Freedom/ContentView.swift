import SwiftData
import SwiftUI
import SwarmKit

struct ContentView: View {
    @Environment(SwarmNode.self) private var swarm
    @Environment(TabStore.self) private var tabStore
    @Environment(BookmarkStore.self) private var bookmarkStore
    @Environment(Vault.self) private var vault
    @Environment(BeeIdentityCoordinator.self) private var beeIdentity
    @Environment(BeeReadiness.self) private var beeReadiness
    @Environment(\.scenePhase) private var scenePhase

    // Drives the bookmark toolbar button's fill state — toggling a bookmark
    // updates this query, which flips the icon immediately.
    @Query private var allBookmarks: [Bookmark]

    // Capped history fetch for the address-bar autocomplete. 500 is plenty
    // to satisfy a typed substring without materialising the whole table.
    @Query(Self.suggestionHistoryDescriptor) private var suggestionHistory: [HistoryEntry]

    /// The status/error row above the progress bar. Only one is ever
    /// visible at a time — input parse failures and ENS resolve failures
    /// share the red channel; ENS "Resolving…" takes the info channel.
    enum Banner: Equatable {
        case resolving(name: String)
        case error(message: String)
    }

    @State private var addressText: String = ""
    @State private var banner: Banner? = nil
    @State private var isShowingTabSwitcher = false
    @State private var isShowingHistory = false
    @State private var isShowingBookmarks = false
    @State private var isShowingSettings = false
    @State private var isShowingWallet = false
    @State private var isShowingNode = false
    @FocusState private var addressFocused: Bool

    private var activeURL: URL? { tabStore.activeTab?.displayURL }

    /// Swipe-dismiss goes through `resolvePendingApproval(.denied)` on the
    /// tab, which is the single point that resumes the bridge's parked
    /// continuation.
    private var approvalBinding: Binding<ApprovalRequest?> {
        Binding(
            get: { tabStore.activeTab?.pendingEthereumApproval },
            set: { newValue in
                if newValue == nil {
                    tabStore.activeTab?.resolvePendingApproval(.denied)
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            nodeStatusBar
            addressBar
            if let banner {
                bannerRow(banner)
            }
            progressBar
            webArea
                .overlay(alignment: .top) {
                    if !suggestions.isEmpty {
                        HistorySuggestions(matches: suggestions) { suggestion in
                            guard let classified = BrowserURL.classify(suggestion.url) else { return }
                            navigate(to: classified)
                        }
                    }
                }
            toolbar
        }
        .sheet(isPresented: $isShowingTabSwitcher) {
            TabSwitcher(isPresented: $isShowingTabSwitcher)
        }
        .sheet(isPresented: $isShowingHistory) {
            HistoryView(onSelect: { browserURL in
                navigate(to: browserURL)
                isShowingHistory = false
            })
        }
        .sheet(isPresented: $isShowingBookmarks) {
            BookmarksView(onSelect: { browserURL in
                navigate(to: browserURL)
                isShowingBookmarks = false
            })
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $isShowingWallet) {
            WalletSheet(isPresented: $isShowingWallet)
        }
        .sheet(isPresented: $isShowingNode) {
            NodeSheet(isPresented: $isShowingNode)
        }
        .sheet(item: approvalBinding) { approval in
            switch approval.kind {
            case .connect:
                ApproveConnectSheet(approval: approval)
            case .personalSign(let preview):
                ApproveSignSheet(approval: approval, kind: .personalSign(preview))
            case .typedData(let typed):
                ApproveSignSheet(approval: approval, kind: .typedData(typed))
            case .sendTransaction(let details):
                ApproveTxSheet(approval: approval, details: details)
            case .switchChain(let details):
                ApproveChainSwitchSheet(approval: approval, details: details)
            }
        }
        .onChange(of: tabStore.activeTab?.displayURL) { _, new in
            guard !addressFocused else { return }
            addressText = new?.absoluteString ?? ""
        }
        .onChange(of: tabStore.activeRecordID) { _, _ in
            addressFocused = false
            addressText = activeURL?.absoluteString ?? ""
            // Previous tab's banner is irrelevant to the new tab.
            banner = nil
        }
        .onChange(of: tabStore.activeTab?.ensStatus ?? .idle) { _, new in
            switch new {
            case .idle: banner = nil
            case .resolving(let name): banner = .resolving(name: name)
            case .failed(let message): banner = .error(message: message)
            }
        }
        .onChange(of: scenePhase) { _, new in
            if new == .background {
                Task { await tabStore.captureActive() }
                // Auto-lock on background — if a thief grabs an unlocked
                // phone and switches away from Freedom, the wallet relocks
                // immediately. `lock()` is a no-op when already locked/empty.
                vault.lock()
            }
        }
        // Self-heal hooks: if a previous identity swap was interrupted
        // (app crash, force-quit) the bee node could be running with a
        // stale identity. The coordinator's `checkAndHeal` is idempotent
        // and gates internally — safe to call on every transition.
        .onChange(of: vault.state) { _, _ in
            beeIdentity.checkAndHeal(vault: vault, swarm: swarm)
        }
        .onChange(of: swarm.status) { _, _ in
            beeIdentity.checkAndHeal(vault: vault, swarm: swarm)
        }
        .alert(
            "Swarm node update failed",
            isPresented: Binding(
                get: { beeIdentity.isFailed },
                set: { if !$0 { beeIdentity.dismissError() } }
            ),
            presenting: beeIdentity.failedMessage
        ) { _ in
            Button("Retry") { beeIdentity.retry() }
            Button("Cancel", role: .cancel) { beeIdentity.dismissError() }
        } message: { message in
            Text(message)
        }
    }

    private var nodeStatusBar: some View {
        HStack(spacing: 8) {
            Circle().frame(width: 8, height: 8).foregroundStyle(swarm.status.color)
            Text(swarm.status.rawValue).font(.caption).monospaced()
            if beeIdentity.status == .swapping {
                Text("· updating identity")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let suffix = readinessSuffix {
                Text("· \(suffix)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(swarm.peerCount) peers")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            // Reserve the shield slot even when there's no trust, so the
            // text field doesn't jump horizontally as tabs switch between
            // ENS-resolved and plain pages.
            Group {
                if let trust = tabStore.activeTab?.currentTrust {
                    TrustShield(trust: trust)
                } else {
                    Color.clear
                }
            }
            .frame(width: 28, height: 28)
            TextField("name.eth, bzz://<hash>, or https://…", text: $addressText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($addressFocused)
                .onSubmit(navigate)
            if addressFocused {
                Button("Go", action: navigate)
                    .buttonStyle(.borderedProminent)
            } else if let active = tabStore.activeTab, active.isLoading {
                Button { active.stop() } label: {
                    Image(systemName: "xmark")
                }
            } else {
                Button { tabStore.activeTab?.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(tabStore.activeTab?.displayURL == nil)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    @ViewBuilder private var progressBar: some View {
        if let active = tabStore.activeTab, active.isLoading, active.progress > 0, active.progress < 1 {
            ProgressView(value: active.progress)
                .tint(.accentColor)
                .scaleEffect(y: 0.5)
        } else {
            Color.clear.frame(height: 2)
        }
    }

    @ViewBuilder private var webArea: some View {
        if let active = tabStore.activeTab, active.hasNavigated {
            if let gate = active.pendingGate {
                ENSInterstitial(gate: gate, tab: active)
            } else {
                // .id forces SwiftUI to recreate the representable when the
                // active tab changes — otherwise it reuses the prior UIView
                // (which is the *previous* tab's WKWebView) and we show the
                // wrong page.
                BrowserWebView(tab: active).id(active.recordID)
            }
        } else {
            HomePage(onNavigate: navigate(to:))
        }
    }

    @ViewBuilder private func bannerRow(_ banner: Banner) -> some View {
        switch banner {
        case .resolving(let name):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Resolving \(name)…").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color(.secondarySystemBackground))
        case .error(let message):
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message).font(.caption)
                Spacer()
                Button { self.banner = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(Color.red)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            toolbarButton("chevron.backward", enabled: tabStore.activeTab?.canGoBack == true) {
                tabStore.activeTab?.goBack()
            }
            toolbarButton("chevron.forward", enabled: tabStore.activeTab?.canGoForward == true) {
                tabStore.activeTab?.goForward()
            }
            Spacer()
            shareButton
            Spacer()
            bookmarkButton
            Spacer()
            Button { isShowingTabSwitcher = true } label: {
                tabsButtonLabel.frame(width: 44, height: 44)
            }
            Spacer()
            toolbarButton("creditcard.fill", enabled: true) { isShowingWallet = true }
            Spacer()
            toolbarButton("circle.hexagongrid.fill", enabled: true) { isShowingNode = true }
            Spacer()
            menuButton
        }
        .padding(.horizontal, 12)
        .background(Color(.secondarySystemBackground))
    }

    @ViewBuilder private var shareButton: some View {
        if let url = activeURL {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
            }
        } else {
            toolbarButton("square.and.arrow.up", enabled: false) {}
        }
    }

    private var bookmarkedURLs: Set<URL> {
        Set(allBookmarks.map(\.url))
    }

    private var suggestions: [HistorySuggestion] {
        let trimmed = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard addressFocused, !trimmed.isEmpty else { return [] }
        let lower = trimmed.lowercased()
        let bookmarkURLs = bookmarkedURLs

        func matches(title: String, url: URL) -> Bool {
            title.lowercased().contains(lower)
            || url.absoluteString.lowercased().contains(lower)
        }

        var seen = Set<URL>()
        var items: [HistorySuggestion] = []

        // History first — its sort order makes the first occurrence per URL
        // the most-recent visit.
        for entry in suggestionHistory where matches(title: entry.displayTitle, url: entry.url) {
            guard !seen.contains(entry.url) else { continue }
            seen.insert(entry.url)
            items.append(HistorySuggestion(
                url: entry.url,
                title: entry.displayTitle,
                timestamp: entry.visitedAt,
                isBookmark: bookmarkURLs.contains(entry.url)
            ))
        }
        // Then bookmarks the user has never visited through history.
        for bookmark in allBookmarks where matches(title: bookmark.displayTitle, url: bookmark.url) {
            guard !seen.contains(bookmark.url) else { continue }
            seen.insert(bookmark.url)
            items.append(HistorySuggestion(
                url: bookmark.url,
                title: bookmark.displayTitle,
                timestamp: bookmark.createdAt,
                isBookmark: true
            ))
        }

        items.sort { $0.timestamp > $1.timestamp }
        return Array(items.prefix(5))
    }

    private static var suggestionHistoryDescriptor: FetchDescriptor<HistoryEntry> {
        var d = FetchDescriptor<HistoryEntry>(
            sortBy: [SortDescriptor(\.visitedAt, order: .reverse)]
        )
        d.fetchLimit = 500
        return d
    }

    private var isActiveURLBookmarked: Bool {
        guard let url = activeURL else { return false }
        return bookmarkedURLs.contains(url)
    }

    private var bookmarkButton: some View {
        Button {
            guard let tab = tabStore.activeTab, let url = activeURL else { return }
            bookmarkStore.toggle(url: url, title: tab.title)
        } label: {
            Image(systemName: isActiveURLBookmarked ? "star.fill" : "star")
                .font(.system(size: 20))
                .frame(width: 44, height: 44)
        }
        .disabled(activeURL == nil)
    }

    private var menuButton: some View {
        Menu {
            Button {
                isShowingBookmarks = true
            } label: {
                Label("Bookmarks", systemImage: "book")
            }
            Button {
                isShowingHistory = true
            } label: {
                Label("History", systemImage: "clock")
            }
            Divider()
            Button {
                isShowingSettings = true
            } label: {
                Label("Settings", systemImage: "gear")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20))
                .frame(width: 44, height: 44)
        }
    }

    private var tabsButtonLabel: some View {
        ZStack {
            Image(systemName: "square.on.square").font(.system(size: 20))
            if !tabStore.records.isEmpty {
                Text("\(tabStore.records.count)")
                    .font(.caption2).bold()
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
                    .offset(x: 14, y: -10)
            }
        }
    }

    private func toolbarButton(_ systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .frame(width: 44, height: 44)
        }
        .disabled(!enabled)
    }

    /// Status-bar suffix for light-mode readiness — shows what bee is
    /// busy with (starting, syncing) so the user always knows without
    /// having to open the node sheet. Nil means "nothing noteworthy" →
    /// status bar stays compact.
    private var readinessSuffix: String? {
        // When bee crashed, the prefix already says "failed". Don't
        // contradict it with "· starting" derived from BeeReadiness'
        // not-running guard.
        if swarm.status == .failed { return nil }
        switch beeReadiness.state {
        case .browsingOnly, .ready: return nil
        case .initializing: return "starting"
        case .startingUp: return "starting up"
        case .syncingPostage(let percent, _, _): return "syncing \(percent)%"
        }
    }

    private func navigate() {
        guard let parsed = BrowserURL.parse(addressText) else {
            banner = .error(message: "Expected a name (foo.eth), bzz://<hash>, or https://…")
            return
        }
        navigate(to: parsed)
    }

    private func navigate(to browserURL: BrowserURL) {
        banner = nil
        addressFocused = false
        addressText = browserURL.url.absoluteString
        tabStore.navigateActive(to: browserURL)
    }
}
