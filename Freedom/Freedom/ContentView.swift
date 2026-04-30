import SwiftData
import SwiftUI
import SwarmKit

struct ContentView: View {
    @Environment(SwarmNode.self) private var swarm
    @Environment(TabStore.self) private var tabStore
    @Environment(BookmarkStore.self) private var bookmarkStore
    @Environment(Vault.self) private var vault
    @Environment(BeeIdentityCoordinator.self) private var beeIdentity
    @Environment(SettingsStore.self) private var settings
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
    @State private var isShowingSettings = false
    @State private var isShowingWallet = false
    @State private var isShowingNode = false
    @FocusState private var addressFocused: Bool
    /// Gates suggestions so they don't appear before the user actually
    /// types in the prefilled URL (Safari behavior). Reset on every
    /// focus entry; latched true on the first text change while focused.
    @State private var userEditedText: Bool = false
    /// "Edit mode UI" is decoupled from `@FocusState`: scrolling the
    /// start page dismisses the keyboard (via `.scrollDismissesKeyboard`)
    /// but the edit-mode chrome (cancel button, expanded URL pill) stays
    /// — Safari's behavior. Set true on focus entry, cleared only by
    /// explicit `exitEditMode()` paths (cancel, navigate, tab switch).
    @State private var isEditing: Bool = false

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
            // Top-safe-area background only when the page declares a
            // `<meta name="theme-color">`. Otherwise transparent, so
            // the webview (which then ignores the top safe area too)
            // renders right up to the screen edge — Safari's model.
            topSafeAreaBackground
                .ignoresSafeArea()
            // Webview content flows under the floating bottom pill bar
            // (Safari-style); WKWebView's automatic content insets keep
            // the user able to scroll content past the bar. Top edge:
            // respected when there's a theme-color (so it doesn't paint
            // over the colored status-bar region), ignored otherwise.
            // The safe-area treatment is applied INSIDE `webArea`, only
            // to the webview branch — HomePage's ScrollView wants to
            // respect the top safe area (same as in edit-mode takeover)
            // so its content doesn't sit behind the status bar.
            webArea
            // Webview stays mounted under editingContent so WKWebView
            // state survives a quick edit.
            if isEditing {
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
        .animation(.snappy(duration: 0.25), value: isEditing)
        .animation(.snappy(duration: 0.25), value: tabStore.activeTab?.chromeIsCompact)
        .sheet(isPresented: $isShowingTabSwitcher) {
            TabSwitcher(isPresented: $isShowingTabSwitcher)
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
            // Focus arrives → enter edit mode. Focus loss alone doesn't
            // exit edit mode (scrolling the start page dismisses the
            // keyboard but keeps the chrome in edit-mode form).
            if focused { isEditing = true }
        }
        .onChange(of: isEditing) { _, editing in
            // Reset the user-typed gate on a fresh edit session — but
            // only on the false→true transition, so re-focusing the URL
            // pill after a scroll-dismiss doesn't wipe out userEditedText
            // mid-session and bounce the user back to HomePage.
            if editing { userEditedText = false }
        }
        .onChange(of: addressText) { _, _ in
            // The displayURL→addressText sync above is gated on
            // !addressFocused, so any focused-time write is user-driven.
            if addressFocused { userEditedText = true }
        }
        .onChange(of: tabStore.activeRecordID) { _, _ in
            exitEditMode()
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
        if isEditing { return .editing }
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
                        isEditing: isEditing,
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
                        nodeStatsLine: nodeStatsLine,
                        isURLBookmarked: isActiveURLBookmarked,
                        canBookmark: activeURL != nil,
                        shareURL: activeURL,
                        onBookmarkToggle: toggleBookmark,
                        onTabs: { isShowingTabSwitcher = true },
                        onNewTab: { tabStore.newTab() },
                        onWallet: { isShowingWallet = true },
                        onNode: { isShowingNode = true },
                        onSettings: { isShowingSettings = true }
                    )
                    // iOS 26's `.buttonStyle(.glass)` reserves a slightly
                    // wider layout box than the visible circle, so the
                    // HStack's 8pt spacing leaves a bigger visual gap on
                    // this side than on the NavPill side. Pull it back
                    // by a few points so the URL pill sits centered
                    // between equally-spaced neighbors.
                    .padding(.leading, -5)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 0)
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
                .frame(width: 50, height: 50)
        }
        .buttonStyle(.plain)
        .glassPill()
    }

    @ViewBuilder private var editingContent: some View {
        if userEditedText {
            // Sticky for the session: once the user types or clears the
            // bar, HomePage doesn't return until cancel + re-tap (Safari).
            VStack(alignment: .leading, spacing: 6) {
                Text("Suggestions from Bookmarks · History · Tabs")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                HistorySuggestions(matches: suggestions) { suggestion in
                    guard let classified = BrowserURL.classify(suggestion.url) else { return }
                    navigate(to: classified)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Bounded background — `.scaledToFill` is sized by this
            // view's frame, not the ZStack's intrinsic size. Sibling
            // layout would otherwise let the 3:2 image leak its
            // dimensions into the enclosing layout and overflow the
            // suggestions horizontally (same trap HomePage navigates
            // around with the same `.background { Image … }` pattern).
            .background {
                Image("HomeHero")
                    .resizable()
                    .scaledToFill()
                    .clipped()
                    .overlay(Color.black.opacity(0.65))
                    .ignoresSafeArea()
            }
            // Dim hero is dark — force light text colors so
            // `.primary`/`.secondary` inside HistorySuggestions are
            // legible regardless of the system color scheme.
            .environment(\.colorScheme, .dark)
        } else {
            HomePage(onNavigate: navigate(to:))
        }
    }

    /// Drops out of edit mode and restores the active tab's URL.
    /// (Clearing the typed text is the in-pill ✕-circle, separate.)
    private func cancelEdit() {
        exitEditMode()
        resetAddressTextToActiveURL()
    }

    /// The single explicit "leave edit mode" path — clears both the
    /// chrome's edit-mode flag and the keyboard focus. Direct focus
    /// loss alone (e.g. scroll-dismiss-keyboard) deliberately does not
    /// exit edit mode; only callers that mean to leave the edit
    /// surface entirely call this.
    private func exitEditMode() {
        isEditing = false
        addressFocused = false
    }

    private func resetAddressTextToActiveURL() {
        addressText = activeURL?.absoluteString ?? ""
    }

    /// Top-safe-area background. The page's parsed
    /// `<meta name="theme-color">` if it set one, otherwise transparent
    /// — and the webview takes over the top edge in that case (see
    /// `webAreaIgnoredEdges`).
    private var topSafeAreaBackground: Color {
        tabStore.activeTab?.themeColor.map(Color.init) ?? .clear
    }

    /// Webview ignores the bottom safe area always (so content flows
    /// under the floating pill bar). Top is only ignored when the page
    /// hasn't set a theme-color — when it has, we yield the top edge to
    /// the colored background layer instead of painting page content
    /// behind the status bar.
    private var webAreaIgnoredEdges: Edge.Set {
        tabStore.activeTab?.themeColor == nil ? [.top, .bottom] : .bottom
    }

    /// "Light · 32 peers" / "Ultralight · 0 peers" / "Off" — drives the
    /// menu's node-stats subtitle. Status takes precedence when the
    /// node isn't running so the line doesn't pretend to have peers.
    private var nodeStatsLine: String {
        guard swarm.status == .running else { return swarm.status.rawValue.capitalized }
        let mode = settings.beeNodeMode == .light ? "Light" : "Ultralight"
        let peers = "\(swarm.peerCount) peer\(swarm.peerCount == 1 ? "" : "s")"
        return "\(mode) · \(peers)"
    }


    @ViewBuilder private var webArea: some View {
        if let active = tabStore.activeTab, active.hasNavigated {
            Group {
                if let gate = active.pendingGate {
                    ENSInterstitial(gate: gate, tab: active)
                } else {
                    // .id forces SwiftUI to recreate the representable when the
                    // active tab changes — otherwise it reuses the prior UIView
                    // (which is the *previous* tab's WKWebView) and we show the
                    // wrong page.
                    BrowserWebView(tab: active).id(active.recordID)
                }
            }
            .ignoresSafeArea(edges: webAreaIgnoredEdges)
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
        guard isEditing, userEditedText, !trimmed.isEmpty else { return [] }
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
        // Then open-tab URLs the user hasn't visited via history yet.
        for record in tabStore.records {
            guard let url = record.url, !seen.contains(url) else { continue }
            let title = record.title ?? url.absoluteString
            guard matches(title: title, url: url) else { continue }
            seen.insert(url)
            items.append(HistorySuggestion(
                url: url,
                title: title,
                timestamp: record.lastActiveAt,
                isBookmark: bookmarkURLs.contains(url)
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
        exitEditMode()
        addressText = browserURL.url.absoluteString
        tabStore.navigateActive(to: browserURL)
    }
}
