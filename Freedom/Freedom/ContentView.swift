import SwiftData
import SwiftUI
import SwarmKit

struct ContentView: View {
    @Environment(SwarmNode.self) private var swarm
    @Environment(TabStore.self) private var tabStore
    @Environment(BookmarkStore.self) private var bookmarkStore
    @Environment(Vault.self) private var vault
    @Environment(BeeIdentityCoordinator.self) private var beeIdentity
    @Environment(\.scenePhase) private var scenePhase

    // Drives the menu's bookmark-toggle row (star fill + label text).
    // Updating a bookmark flips this query, which flips the icon immediately.
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
    /// Gates suggestions so they don't appear before the user actually
    /// types in the prefilled URL (Safari behavior). Reset on every
    /// focus entry; latched true on the first text change while focused.
    @State private var userEditedText: Bool = false

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

    private var swarmApprovalBinding: Binding<ApprovalRequest?> {
        Binding(
            get: { tabStore.activeTab?.pendingSwarmApproval },
            set: { newValue in
                if newValue == nil {
                    tabStore.activeTab?.resolvePendingSwarmApproval(.denied)
                }
            }
        )
    }

    var body: some View {
        ZStack {
            webArea
                .ignoresSafeArea(edges: .top)
            // Webview stays mounted under editingContent so WKWebView
            // state survives a quick edit.
            if addressFocused {
                editingContent
                    .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let banner {
                    bannerRow(banner)
                }
                pillBar
            }
            .frame(maxWidth: .infinity)
            // Block stray taps in the chrome bar's transparent gaps from
            // falling through to the editingContent (HomePage) below —
            // otherwise tapping the cancel pill also "clicks" the bookmark
            // card it happens to be sitting on top of.
            .contentShape(Rectangle())
            .onTapGesture { }
        }
        .animation(.snappy(duration: 0.25), value: addressFocused)
        .animation(.snappy(duration: 0.25), value: tabStore.activeTab?.chromeIsCompact)
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
            case .swarmConnect, .swarmPublish, .swarmFeedAccess:
                EmptyView()  // routed via swarmApprovalBinding's sheet
            }
        }
        .sheet(item: swarmApprovalBinding) { approval in
            switch approval.kind {
            case .swarmConnect:
                SwarmConnectSheet(approval: approval)
            case .swarmPublish(let details):
                SwarmPublishSheet(approval: approval, details: details)
            case .swarmFeedAccess(let details):
                SwarmFeedAccessSheet(approval: approval, details: details)
            case .connect, .personalSign, .typedData,
                 .sendTransaction, .switchChain:
                EmptyView()  // routed via approvalBinding's sheet
            }
        }
        .onChange(of: tabStore.activeTab?.displayURL) { _, new in
            guard !addressFocused else { return }
            addressText = new?.absoluteString ?? ""
        }
        .onChange(of: addressFocused) { _, focused in
            // Reset on every entry so suggestions don't appear from the
            // user's previous edit session before they've typed.
            if focused { userEditedText = false }
        }
        .onChange(of: addressText) { _, _ in
            // The displayURL→addressText sync above is gated on
            // !addressFocused, so any focused-time write is user-driven.
            if addressFocused { userEditedText = true }
        }
        .onChange(of: tabStore.activeRecordID) { _, _ in
            addressFocused = false
            resetAddressTextToActiveURL()
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

    /// Three chrome states drive the pill bar layout. Editing wins over
    /// compact (a tap-to-edit while scrolled re-expands).
    private enum ChromeMode { case normal, editing, compact }
    private var chromeMode: ChromeMode {
        if addressFocused { return .editing }
        if tabStore.activeTab?.chromeIsCompact == true { return .compact }
        return .normal
    }

    private var pillBar: some View {
        let active = tabStore.activeTab
        let mode = chromeMode
        return GlassChromeGroup(spacing: 8) {
            HStack(spacing: 8) {
                if mode == .normal {
                    NavPill(
                        canGoBack: active?.canGoBack == true,
                        canGoForward: active?.canGoForward == true,
                        onBack: { tabStore.activeTab?.goBack() },
                        onForward: { tabStore.activeTab?.goForward() }
                    )
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                if mode == .compact {
                    Spacer(minLength: 0)
                    CompactURLPill(
                        trust: active?.currentTrust,
                        displayURL: active?.displayURL,
                        onTap: expandFromCompact
                    )
                    .transition(.opacity)
                    .simultaneousGesture(swipeUpToTabs)
                    Spacer(minLength: 0)
                } else {
                    URLPill(
                        text: $addressText,
                        isFocused: $addressFocused,
                        trust: active?.currentTrust,
                        isLoading: active?.isLoading == true,
                        progress: active?.progress ?? 0,
                        displayURL: active?.displayURL,
                        onSubmit: navigate,
                        onReload: { tabStore.activeTab?.reload() },
                        onStop: { tabStore.activeTab?.stop() }
                    )
                    .frame(maxWidth: .infinity)
                    .simultaneousGesture(swipeUpToTabs)
                }
                if mode == .editing {
                    cancelPill
                        .transition(.opacity)
                } else if mode == .normal {
                    MenuPill(
                        nodeStatus: swarm.status,
                        peerCount: swarm.peerCount,
                        isURLBookmarked: isActiveURLBookmarked,
                        canBookmark: activeURL != nil,
                        shareURL: activeURL,
                        onBookmarkToggle: toggleBookmark,
                        onTabs: { isShowingTabSwitcher = true },
                        onWallet: { isShowingWallet = true },
                        onNode: { isShowingNode = true },
                        onBookmarks: { isShowingBookmarks = true },
                        onHistory: { isShowingHistory = true },
                        onSettings: { isShowingSettings = true }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// Compact pill tap: just restore full chrome (same effect as
    /// scrolling up). User taps the now-full URL pill again to enter
    /// edit mode — Safari's two-tap pattern from the compact state.
    private func expandFromCompact() {
        tabStore.activeTab?.chromeIsCompact = false
    }

    /// Safari's pro-user gesture: upward swipe from the URL pill opens
    /// the tab switcher. `minimumDistance: 30` keeps quick taps as taps
    /// — Button cancels its own tap past ~10pt of movement, so the
    /// 10-30pt zone is a deliberate no-op. Skipped while editing.
    private var swipeUpToTabs: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard !addressFocused,
                      value.translation.height < -50 else { return }
                isShowingTabSwitcher = true
            }
    }

    private var cancelPill: some View {
        Button(action: cancelEdit) {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassPill()
    }

    @ViewBuilder private var editingContent: some View {
        if userEditedText {
            // Sticky for the session: once the user types or clears the
            // bar, HomePage doesn't return until cancel + re-tap (Safari).
            HistorySuggestions(matches: suggestions) { suggestion in
                guard let classified = BrowserURL.classify(suggestion.url) else { return }
                navigate(to: classified)
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(.systemBackground))
        } else {
            HomePage(onNavigate: navigate(to:))
        }
    }

    /// Drops out of edit mode and restores the active tab's URL.
    /// (Clearing the typed text is the in-pill ✕-circle, separate.)
    private func cancelEdit() {
        addressFocused = false
        resetAddressTextToActiveURL()
    }

    private func resetAddressTextToActiveURL() {
        addressText = activeURL?.absoluteString ?? ""
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

    private var bookmarkedURLs: Set<URL> {
        Set(allBookmarks.map(\.url))
    }

    private var suggestions: [HistorySuggestion] {
        let trimmed = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard addressFocused, userEditedText, !trimmed.isEmpty else { return [] }
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
        return allBookmarks.contains { $0.url == url }
    }

    private func toggleBookmark() {
        guard let tab = tabStore.activeTab, let url = activeURL else { return }
        bookmarkStore.toggle(url: url, title: tab.title)
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
