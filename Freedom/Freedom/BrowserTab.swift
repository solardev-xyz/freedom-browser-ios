import Foundation
import IPFSKit
import Observation
import UIKit
import web3
import WebKit
import OSLog

private let tabLog = Logger(subsystem: "com.browser.Freedom", category: "BrowserTab")

@MainActor
@Observable
final class BrowserTab {
    enum ENSStatus: Equatable {
        case idle
        /// In-flight ENS resolution. `url` is the pseudo `ens://<name>`
        /// form that drives the address bar until WebKit takes over —
        /// stays the source of truth for `displayURL` while `url` is
        /// still the prior page's address (or nil on a cold tab).
        case resolving(name: String, url: URL)
        /// In-flight `html()` fetch for a contract-hosted app; `url` is
        /// the friendly `web3://…` form for the address bar.
        case fetchingOnchain(app: OnchainAppRef, url: URL)
        case failed(message: String)
    }

    enum BottomChromeMode {
        /// Pill bar floats over a full-bleed webview. Page content
        /// extends to the bottom edge of the screen; chrome is purely
        /// translucent overlay. Used for sites without prominent
        /// bottom UI (most pages).
        case overlay
        /// Webview is bounded above the pill bar; the chrome region
        /// gets a solid background. Used when the page declares its
        /// own fixed/sticky bottom nav so it stays tappable.
        case reserved
    }

    /// A gated navigation waiting for user consent. Rendered in place of
    /// the webview until the user continues (unverified only) or backs
    /// out (all gates). Conflict and anchorDisagreement are security
    /// signals with no continue option.
    enum Gate: Equatable {
        case unverifiedUntrusted(url: URL, trust: ENSTrust)
        case conflict(groups: [ENSConflictGroup], trust: ENSTrust)
        case anchorDisagreement(largestBucketSize: Int, total: Int, threshold: Int)
        /// Contract-hosted app whose `html()` only a public RPC vouched
        /// for. Holds the exact fetched bytes: "Continue once" runs
        /// these, never a fresh fetch (desktop PR #232).
        case unverifiedOnchain(document: OnchainAppDocument, url: URL)
        /// The name resolved on a transport other than the one the user
        /// typed or clicked. "Open on <resolved>://" re-navigates
        /// without the assertion.
        case codecMismatch(name: String, path: String, requested: ENSContentCodec, resolved: ENSContentCodec)
        /// Contract-hosted app whose `html()` the chain's endpoints
        /// disagreed about, with no verified tier to settle it. No
        /// continue: one of them is lying or the chain is mid-reorg.
        case conflictOnchain(document: OnchainAppDocument, url: URL)
    }

    let recordID: UUID

    var url: URL?
    var title: String = ""
    var progress: Double = 0
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var isLoading: Bool = false
    /// True while the user is scrolling down the page — drives the
    /// Safari-style chrome shrink. Resets to false on scroll-up and
    /// near the top of the page (which also catches fresh navigations,
    /// since contentOffset jumps to 0 on every WebKit commit).
    var chromeIsCompact: Bool = false
    /// Color extracted from the page's `<meta name="theme-color">` (when
    /// present + parseable as hex). Drives the top-safe-area background
    /// behind the webview so a page like Apple's nav-bar-orange or
    /// GitHub's near-black extends seamlessly into the status bar
    /// region. `nil` falls back to the system background color.
    var themeColor: UIColor?
    /// Whether the page has a "real" fixed/sticky bottom UI (nav bar,
    /// tab bar, action bar). Drives the chrome's overlay-vs-reserved
    /// mode: in `.overlay`, our pill bar floats over a full-bleed
    /// webview (Safari's "Google.com" mode); in `.reserved`, the
    /// webview stops above the pill bar and the chrome region gets a
    /// solid theme-color background, so the page's bottom nav stays
    /// interactive (Safari's "Instagram" mode).
    var bottomChromeMode: BottomChromeMode = .overlay
    /// Background color sampled directly from the detected bottom-nav
    /// element. Preferred over `themeColor` for painting the chrome
    /// region in `.reserved` mode — gives a seamless visual edge with
    /// the page's nav above. `nil` falls back to `themeColor`, then
    /// system background.
    var bottomNavColor: UIColor?
    private(set) var hasNavigated: Bool = false

    var ensStatus: ENSStatus = .idle

    /// Trust metadata from the last ENS resolution or onchain-app
    /// fetch. The address-bar shield (M4.10) reads this; nil means the
    /// current page wasn't reached through either.
    var currentTrust: ENSTrust?

    /// Set while the page is a contract-hosted app: what the shield
    /// shows next to the trust (network, contract, document hash,
    /// source). Cleared when the webview leaves the `web3:` origin.
    var currentOnchain: OnchainAppProvenance?

    /// Non-nil when a navigation is blocked by an interstitial. The UI
    /// renders an ENSInterstitial in place of the webview; the gate is
    /// cleared by dismissGate() or continuePastGate().
    var pendingGate: Gate?

    /// URL the UI presents. During the in-flight resolve phase the
    /// pseudo `ens://<name>` form carried on `.resolving` keeps the
    /// address bar locked on the user-typed name; once resolution
    /// hands off to WebKit, `url` (now `<codec>://name/`) is what the
    /// address bar shows, matching desktop Freedom's resolved-transport
    /// display.
    var displayURL: URL? {
        switch ensStatus {
        case .resolving(_, let pending), .fetchingOnchain(_, let pending): return pending
        case .idle, .failed: return url.map(Self.presented)
        }
    }

    /// The user-facing form of a URL WebKit reports: a canonical
    /// `web3://<addr>.eip155-<n>/` origin reads as `web3://<addr>[:<n>]/`
    /// in the address bar, history and bookmarks; everything else is
    /// itself.
    static func presented(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == OnchainAppRef.scheme,
              let (app, tail) = OnchainAppRef.parse(url) else { return url }
        return app.displayURL(tail: tail)
    }

    /// Parked approval. The bridge awaits `ApprovalResolver`; the sheet
    /// presents via ContentView. Call `resolvePendingApproval` from any
    /// dismissal path (tab close, swipe) so the resolver fires exactly once
    /// — `ApprovalResolver` is the fire-once guard.
    var pendingEthereumApproval: ApprovalRequest?
    var pendingSwarmApproval: ApprovalRequest?
    var pendingRadicleApproval: ApprovalRequest?
    /// A site permission prompt parked on this tab (camera, microphone,
    /// motion). One at a time; later requests queue behind it.
    var pendingPermissionRequest: SitePermissionRequest?
    /// Private tab (see `TabRecord.isPrivate`).
    let isPrivate: Bool
    /// Site permission decisions: the profile store, or, for a private
    /// tab, an in-memory store that dies with the tab — decisions made
    /// here are never remembered and never touch the normal profile's.
    @ObservationIgnored private let sitePermissions: SitePermissionStore
    /// Set by TabStore: open `url` in a new tab, in front or behind.
    @ObservationIgnored var onOpenInNewTab: ((URL, _ background: Bool) -> Void)?
    /// The page's current text selection (relayed by the touch script).
    @ObservationIgnored var lastSelection = ""
    @ObservationIgnored private let selectionRelay = SelectionRelay()
    /// The system find navigator is showing: the bottom chrome steps
    /// aside so the navigator takes the address bar's place (Safari).
    var isFinding = false
    @ObservationIgnored private var findWatchTask: Task<Void, Never>?
    @ObservationIgnored private var permissionQueue: [SitePermissionRequest] = []

    /// WebKit asked on behalf of `origin`. Remembered decisions and
    /// run-scoped embargoes answer without a prompt; otherwise the request
    /// is parked for the prompt under the address bar. Desktop parity:
    /// dismissing denies once without recording; three dismissals in a
    /// row embargo the site + permission for this run.
    func requestSitePermission(
        origin: String?, kinds: [SitePermissionKind], detail: String? = nil,
        decide: @escaping (SitePermissionDecision) -> Void
    ) {
        guard let origin, !kinds.isEmpty else { decide(.block); return }
        let store = sitePermissions
        if let settled = store.settled(origin: origin, kinds: kinds) {
            decide(settled)
            return
        }
        var answered = false
        let request = SitePermissionRequest(origin: origin, kinds: kinds, detail: detail) { [weak self] answer, remember in
            guard !answered else { return }
            answered = true
            switch answer {
            case .allow:
                store.noteAnswered(origin: origin, kinds: kinds)
                if remember { store.remember(origin: origin, kinds: kinds, decision: .allow) }
                decide(.allow)
            case .block:
                store.noteAnswered(origin: origin, kinds: kinds)
                if remember { store.remember(origin: origin, kinds: kinds, decision: .block) }
                decide(.block)
            case .dismiss:
                store.noteDismissal(origin: origin, kinds: kinds)
                decide(.block)
            }
            self?.advancePermissionQueue()
        }
        if pendingPermissionRequest == nil {
            pendingPermissionRequest = request
        } else {
            permissionQueue.append(request)
        }
    }

    /// A link the browser cannot show (mailto:, tel:, magnet:, an app
    /// scheme): ask the current site's consent, then hand it to the
    /// system. Remembered per site like the other permissions.
    func requestExternalOpen(_ url: URL) {
        let origin = webView.url.flatMap(SitePermissionStore.origin(for:)) ?? displayURL.flatMap(SitePermissionStore.origin(for:))
        requestSitePermission(origin: origin, kinds: [.externalApps], detail: ExternalLinks.appName(for: url)) { decision in
            guard decision == .allow else { return }
            UIApplication.shared.open(url, options: [:]) { opened in
                if !opened { tabLog.notice("[external] nothing handles \(url.scheme ?? "?", privacy: .public)") }
            }
        }
    }

    private func advancePermissionQueue() {
        pendingPermissionRequest = permissionQueue.isEmpty ? nil : permissionQueue.removeFirst()
    }

    /// The page navigated away: withdraw its prompts (denied, nothing
    /// recorded, no dismissal counted — the user never saw them).
    func cancelPermissionPrompts() {
        let parked = [pendingPermissionRequest].compactMap { $0 } + permissionQueue
        permissionQueue = []
        pendingPermissionRequest = nil
        // Deliver the denial without re-entering the queue.
        for request in parked { request.respond(.block, false) }
    }

    func resolvePendingApproval(_ decision: ApprovalRequest.Decision) {
        let pending = pendingEthereumApproval
        pendingEthereumApproval = nil
        pending?.decide(decision)
    }

    func resolvePendingSwarmApproval(_ decision: ApprovalRequest.Decision) {
        let pending = pendingSwarmApproval
        pendingSwarmApproval = nil
        pending?.decide(decision)
    }

    func resolvePendingRadicleApproval(_ decision: ApprovalRequest.Decision) {
        let pending = pendingRadicleApproval
        pendingRadicleApproval = nil
        pending?.decide(decision)
    }

    // The WKWebView is stored, not lazy or computed, because SwiftUI's
    // UIViewRepresentable vends it via `tab.webView` every time the
    // representable is materialized — which happens when the view tree
    // flips between HomePage and BrowserWebView. A single persistent
    // instance keeps navigation state and the bzz scheme handler alive
    // across those flips.
    let webView: WKWebView

    /// Called when a navigation commits successfully (WKNavigationDelegate
    /// didFinish). Used by TabStore to feed the history store.
    var onNavigationFinish: ((URL, String) -> Void)?

    /// Top-level path of the in-flight ipfs/ipns navigation, mirrored
    /// from `ipfsNavContext.topLevelPath` as observable state so
    /// SwiftUI views (URL pill) re-render when a navigation starts
    /// or ends. `IpfsNavContext` itself stays non-`@Observable`
    /// because `IpfsSchemeHandler` mutates its `rootRequestID` on
    /// the URLSession delegate path — a hot per-subresource path
    /// that shouldn't fan out SwiftUI invalidations. This mirror
    /// keeps view tracking bounded to actual navigation
    /// transitions on `BrowserTab` itself.
    private(set) var activeIpfsTopLevelPath: String?

    @ObservationIgnored private let ensResolver: any ENSResolving
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let adblock: AdblockService
    @ObservationIgnored private let ipfs: IPFSNode
    /// Shared with the tab's two `IpfsSchemeHandler` instances. Tracks
    /// the current top-level `ipfs://`/`ipns://` navigation so the
    /// scheme handler can stamp correlation headers and the Rust
    /// gateway can group subresource progress under the parent.
    @ObservationIgnored private let ipfsNavContext = IpfsNavContext()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var lastScrollY: CGFloat = 0
    @ObservationIgnored private var bottomChromeProbeTask: Task<Void, Never>?
    @ObservationIgnored private let navDelegate = NavDelegate()
    /// Serves staged contract-hosted documents under their `web3:`
    /// origin. Nil for popup tabs, whose configuration inherits the
    /// opener's handlers and can't register another.
    @ObservationIgnored private let web3Handler: Web3SchemeHandler?
    @ObservationIgnored private let onchainLoader: OnchainAppLoader
    /// The chain the current onchain app is pinned to; read by the
    /// tab's `RPCRouter` ahead of the wallet's global active chain.
    @ObservationIgnored let chainPin = OnchainChainPin()
    @ObservationIgnored private let uiDelegate = UIDelegate()
    /// TabStore's seam for adopting `window.open` / `target="_blank"`
    /// popups: given the configuration WebKit provides, create + activate
    /// a new tab and return its web view. Unset → WebKit gets nil and
    /// `window.open` returns null in the page (the pre-M-tabs behavior).
    @ObservationIgnored var onCreatePopup: ((WKWebViewConfiguration) -> WKWebView?)?
    /// `window.close()` from a script-opened page — close this tab.
    @ObservationIgnored var onRequestClose: (() -> Void)?
    /// Set by TabStore: an `ethereum:` link (EIP-681) the page asked to
    /// open. Never a page load — the wallet's Send form, prefilled.
    @ObservationIgnored var onEthereumURI: ((URL) -> Void)?
    @ObservationIgnored private var activeResolveTask: Task<Void, Never>?
    @ObservationIgnored private let contentController: WKUserContentController
    @ObservationIgnored fileprivate var walletBridge: EthereumBridge?
    @ObservationIgnored fileprivate var swarmBridge: SwarmBridge?
    @ObservationIgnored fileprivate var radicleBridge: RadicleBridge?
    /// Live preload task ID for the current ipfs/ipns navigation, if
    /// any. Cancelled and re-issued on every committed top-level
    /// navigation; cleared on failure.
    @ObservationIgnored private var activePreloadID: UInt64 = 0

    init(
        recordID: UUID = UUID(),
        isPrivate: Bool = false,
        popupConfiguration: WKWebViewConfiguration? = nil,
        ensResolver: any ENSResolving,
        settings: SettingsStore,
        wallet: WalletServices,
        swarm: SwarmServices,
        radicle: RadicleServices,
        adblock: AdblockService,
        ipfs: IPFSNode
    ) {
        self.recordID = recordID
        self.isPrivate = isPrivate
        self.sitePermissions = isPrivate ? SitePermissionStore(ephemeral: true) : .shared
        self.ensResolver = ensResolver
        self.settings = settings
        self.adblock = adblock
        self.ipfs = ipfs
        self.onchainLoader = OnchainAppLoader(registry: wallet.chainRegistry, chainStore: wallet.chainStore)
        let config: WKWebViewConfiguration
        if let popupConfiguration {
            // WebKit-initiated popup (window.open / target=_blank): the
            // returned web view MUST be created with the configuration
            // WebKit hands to createWebViewWith — it carries the opener's
            // process pool and scheme handlers (bzz/ipfs/ipns), so the
            // popup keeps resolving decentralized schemes; re-registering
            // a handler for an already-registered scheme would throw.
            // Caveat: the inherited ipfs/ipns handlers stamp the OPENER's
            // nav context — correlation-only, and bzz popups (the actual
            // window.open users today) are unaffected.
            config = popupConfiguration
            self.web3Handler = nil
        } else {
            config = WKWebViewConfiguration()
            // Private: a unique in-memory data store — cookies, logins,
            // caches and site data evaporate with the tab (desktop's
            // `private-<uuid>` partition).
            if isPrivate { config.websiteDataStore = .nonPersistent() }
            config.setURLSchemeHandler(BzzSchemeHandler(ensResolver: ensResolver), forURLScheme: "bzz")
            // Contract-hosted apps (ERC-8244). The handler only serves
            // what this tab staged after fetching + gating.
            let web3 = Web3SchemeHandler()
            config.setURLSchemeHandler(web3, forURLScheme: OnchainAppRef.scheme)
            self.web3Handler = web3
            // One handler instance per scheme — WKWebKit requires distinct
            // objects per scheme registration even when the implementation
            // is the same. Both schemes resolve through the same Rust
            // gateway, but each gets its own handler instance.
            config.setURLSchemeHandler(
                IpfsSchemeHandler(
                    node: ipfs,
                    ensResolver: ensResolver,
                    navContext: ipfsNavContext
                ),
                forURLScheme: "ipfs"
            )
            config.setURLSchemeHandler(
                IpfsSchemeHandler(
                    node: ipfs,
                    ensResolver: ensResolver,
                    navContext: ipfsNavContext
                ),
                forURLScheme: "ipns"
            )
            // Read path for Radicle: pages fetch('rad:<rid>/…') public
            // repo data from the embedded node's storage — actions go
            // through the consented window.radicle provider instead.
            config.setURLSchemeHandler(
                RadSchemeHandler(services: radicle),
                forURLScheme: "rad"
            )
        }
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // iOS defaults this to false, which silently voids window.open
        // OUTSIDE a direct tap — dapps that resolve/decrypt something
        // async before opening (ddrive's open-document flow) got null and
        // fell back to same-tab navigation. Desktop Freedom (Electron)
        // permits gesture-less opens; match it. Popup spam from arbitrary
        // pages is the accepted trade-off, same as desktop.
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Always a FRESH content controller — for a popup the inherited one
        // belongs to the opener tab's bridges (its script-message handlers
        // route approvals/subscriptions to that tab, and re-adding handlers
        // under the same names would crash). Swapping it before the web
        // view is created gives this tab its own bridge identity; the
        // provider user scripts are re-injected by the bridges below.
        let contentController = WKUserContentController()
        config.userContentController = contentController
        self.contentController = contentController
        // Adblock rule lists are attached BEFORE the webview is created so
        // they apply to the very first navigation. No-op until the service
        // has finished compiling — early tabs created during cold launch
        // miss the first page's blocking, which is acceptable since the
        // compile is sub-second once warm.
        adblock.attach(to: contentController)
        let freedomWebView = FreedomWebView(frame: .zero, configuration: config)
        self.webView = freedomWebView
        // Find in page: the system find navigator (highlights, next /
        // previous, Done), entered from the address bar's "On This Page"
        // row — Safari's flow, desktop's Cmd+F bar.
        self.webView.isFindInteractionEnabled = true
        self.webView.navigationDelegate = navDelegate
        navDelegate.owner = self
        self.webView.uiDelegate = uiDelegate
        uiDelegate.owner = self
        // Context menus: selection relay + "Search <Engine> for …" on the
        // edit menu; the touch script goes in with the other user scripts.
        selectionRelay.owner = self
        contentController.add(selectionRelay, name: ContextMenuSupport.selectionHandlerName)
        freedomWebView.searchMenuTitle = { [weak self] in
            guard let self else { return nil }
            let engine = SearchEngine.resolve(
                providerID: settings.searchProvider, customName: settings.customSearchName,
                customTemplate: settings.customSearchTemplate
            ).label
            return ContextMenuSupport.selectionMenuTitle(engine: engine, selection: lastSelection)
        }
        freedomWebView.onSearchSelection = { [weak self] in
            guard let self,
                  let url = SearchEngine.buildURL(
                      query: lastSelection, providerID: settings.searchProvider,
                      customName: settings.customSearchName, customTemplate: settings.customSearchTemplate
                  )
            else { return }
            onOpenInNewTab?(url, false)
        }
        // A popup's first navigation is driven by WEBKIT, not by
        // navigate(to:) — which is the only place hasNavigated normally
        // flips. ContentView mounts the web view only when hasNavigated is
        // true, and WebKit won't render (or progress) a popup whose web
        // view never joins the view hierarchy: the tab showed HomePage
        // with the right URL in the pill until a manual reload routed
        // through navigate(). Popups have navigated by definition.
        if popupConfiguration != nil {
            hasNavigated = true
        }

        // Active chain read live so a wallet-UI chain switch is picked up
        // by dapp reads without rebuilding the router. An onchain app's
        // pinned chain wins over it (`chainPin`).
        let chainStore = wallet.chainStore
        let pin = chainPin
        // Identity and wallet are persistent by design, so a private tab
        // gets none of the page-facing providers: no window.ethereum /
        // window.swarm / window.radicle, nothing announces (desktop parity).
        if !isPrivate {
        let router = RPCRouter(
            registry: wallet.chainRegistry,
            permissionStore: wallet.permissionStore,
            activeChain: { WalletDefaults.activeChain(in: chainStore) },
            pinnedChain: { pin.chainID.flatMap { chainStore.chain(id: $0) } }
        )
        self.walletBridge = EthereumBridge(
            tab: self,
            router: router,
            contentController: contentController,
            services: wallet
        )

        let swarmRouter = SwarmRouter(
            isConnected: { swarm.permissionStore.isConnected($0) },
            listFeedsForOrigin: { origin in
                swarm.feedStore.all(forOrigin: origin).map(\.asListFeedsRow)
            },
            nodeFailureReason: swarm.nodeFailureReason,
            feedOwner: { origin, name in
                swarm.feedStore.lookup(origin: origin, name: name)?.owner
            },
            readFeed: { owner, topic, index in
                // Bee's `/feeds/{owner}/{topic}?index=N` does
                // epoch-based "at-or-before" lookup — wrong semantics
                // for SWIP `swarm_readFeedEntry` which needs exact
                // index match. For explicit-index reads, fetch the
                // SOC directly via `/chunks/{socAddress}` (exact)
                // and strip the envelope. Latest reads (no index)
                // stay on `/feeds/...` which correctly returns the
                // current + next-index headers.
                do {
                    if let index {
                        return try await fetchFeedSOC(
                            owner: owner, topic: topic, index: index,
                            bee: swarm.bee
                        )
                    }
                    let result = try await swarm.bee.getFeedPayload(
                        owner: owner, topic: topic, index: nil
                    )
                    return SwarmRouter.FeedRead(
                        payload: result.payload,
                        index: result.index,
                        nextIndex: result.nextIndex
                    )
                } catch BeeAPIClient.Error.notFound {
                    throw SwarmRouter.FeedReadError.notFound
                } catch BeeAPIClient.Error.notRunning {
                    throw SwarmRouter.FeedReadError.unreachable
                }
            },
            readChunkRaw: { reference in
                do {
                    return try await swarm.bee.getChunk(reference: reference)
                } catch BeeAPIClient.Error.notFound {
                    throw SwarmRouter.ChunkReadError.notFound
                } catch BeeAPIClient.Error.notRunning {
                    throw SwarmRouter.ChunkReadError.unreachable
                }
            },
            readBudget: swarm.readBudget
        )
        self.swarmBridge = SwarmBridge(
            tab: self,
            router: swarmRouter,
            contentController: contentController,
            services: swarm
        )

        self.radicleBridge = RadicleBridge(
            tab: self,
            contentController: contentController,
            services: radicle
        )
        }

        observeWebView()
        installPullToRefresh()
    }

    /// Single coordination point for per-navigation preload reinstall.
    /// `removeAllUserScripts()` is called once, then each bridge
    /// reinstalls its own — preserves both `window.ethereum` and
    /// `window.swarm` on every navigation, with the wallet bridge
    /// regenerating its EIP-6963 UUID along the way.
    fileprivate func reinstallPreloads() {
        contentController.removeAllUserScripts()
        walletBridge?.installUserScript()
        swarmBridge?.installUserScript()
        radicleBridge?.installUserScript()
        installContextMenuScript()
        lastSelection = ""
        installContextMenuScript()
        // SWIP messaging: subscriptions are session-scoped — the page
        // that opened them is going away (this runs from
        // didStartProvisionalNavigation), so tear them down like
        // desktop's `did-navigate` hook does.
        swarmBridge?.cancelSubscriptions()
    }

    private func installContextMenuScript() {
        contentController.addUserScript(WKUserScript(
            source: ContextMenuSupport.touchScriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false
        ))
    }

    // MARK: - Context menu actions

    /// The element under the last touch, as the touch script recorded it.
    func touchedElement() async -> ContextMenuSupport.TouchedElement {
        let value = try? await webView.evaluateJavaScript(ContextMenuSupport.touchQuery)
        return ContextMenuSupport.TouchedElement.parse(value)
    }

    func copyToPasteboard(_ url: URL) {
        UIPasteboard.general.url = url
        UIPasteboard.general.string = url.absoluteString
    }

    func share(_ url: URL) {
        guard let presenter = webView.window?.rootViewController?.topMostPresented else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = webView
        presenter.present(sheet, animated: true)
    }

    /// Fetch a web image and add it to Photos (needs the photo-library
    /// add permission; iOS prompts on first use).
    func saveImage(_ url: URL) {
        guard ContextMenuSupport.canSaveImage(url) else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return }
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        }
    }

    private func installPullToRefresh() {
        let control = UIRefreshControl()
        control.addAction(UIAction { [weak self] _ in
            self?.reload()
        }, for: .valueChanged)
        webView.scrollView.refreshControl = control
    }

    private func endRefreshing() {
        webView.scrollView.refreshControl?.endRefreshing()
    }

    deinit {
        observations.forEach { $0.invalidate() }
        bottomChromeProbeTask?.cancel()
    }

    /// Desktop parity: a main-frame response the web view cannot render,
    /// or one served as an attachment, is a download. Sub-frame responses
    /// are left to WebKit (an undisplayable iframe is not a download).
    static func shouldDownload(_ response: WKNavigationResponse) -> Bool {
        guard response.isForMainFrame else { return false }
        return shouldDownload(
            canShowMIMEType: response.canShowMIMEType,
            contentDisposition: (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        )
    }

    static func shouldDownload(canShowMIMEType: Bool, contentDisposition: String?) -> Bool {
        if !canShowMIMEType { return true }
        guard let disposition = contentDisposition?.lowercased() else { return false }
        return disposition.hasPrefix("attachment")
    }

    /// The ENS name a history entry is backed by, or nil for a plain
    /// web/hash entry: `bzz://name.eth/…`, `ipfs://name.eth/…`,
    /// `ipns://name.eth/…` and the `ens://` form all classify as `.ens`.
    static func ensNameToReverify(_ url: URL) -> String? {
        BrowserURL.classify(url)?.name
    }

    /// Desktop #86: Back/Forward restored an ENS-backed page. Re-run
    /// resolution under the current verification settings (the resolver's
    /// own cache applies — this is not a hard reload) and let the fresh
    /// verdict drive the shield and the gates:
    /// - verified / unverified-and-allowed → shield updated in place;
    /// - unverified while "Block unverified" is on → the same interstitial
    ///   a fresh visit gets, over the restored page; "Continue once"
    ///   keeps the page and sets the shield;
    /// - conflict / anchor disagreement → the red gate, no bypass;
    /// - resolution failure → no verdict (shield withheld), page stays;
    ///   the address bar keeps the entry, nothing claims verification.
    /// Nothing here changes the history stack.
    func reverifyTrust(name: String, restored url: URL) {
        hasNavigated = true
        activeResolveTask?.cancel()
        // The old verdict must not survive the traversal, even for the
        // seconds the re-check takes.
        pendingGate = nil
        currentTrust = nil
        ensStatus = .idle
        activeResolveTask = Task { [weak self] in
            guard let self else { return }
            let result: ENSResolvedContent
            do {
                result = try await ensResolver.resolveContent(name)
            } catch ENSResolutionError.conflict(let groups, let trust) {
                if Task.isCancelled { return }
                pendingGate = .conflict(groups: groups, trust: trust)
                return
            } catch ENSResolutionError.anchorDisagreement(let largest, let total, let threshold) {
                if Task.isCancelled { return }
                pendingGate = .anchorDisagreement(largestBucketSize: largest, total: total, threshold: threshold)
                return
            } catch {
                if Task.isCancelled { return }
                tabLog.notice("[ens] re-verify on history nav failed for \(name, privacy: .public): \(ENSErrorFormatting.describe(error), privacy: .public)")
                return
            }
            if Task.isCancelled { return }
            if result.trust.level == .unverified, settings.blockUnverifiedEns {
                pendingGate = .unverifiedUntrusted(url: url, trust: result.trust)
                return
            }
            currentTrust = result.trust
        }
    }

    func navigate(to browserURL: BrowserURL) {
        hasNavigated = true
        activeResolveTask?.cancel()
        resetENSState()
        switch browserURL {
        case .bzz(let target), .ipfs(let target), .ipns(let target), .web(let target):
            loadInWebView(target)
        case .ens(let name, let path, let codec):
            ensStatus = .resolving(name: name, url: browserURL.url)
            activeResolveTask = Task { await resolveAndLoad(name: name, path: path, expectedCodec: codec) }
        case .tez(let name, let path):
            ensStatus = .resolving(name: name, url: browserURL.url)
            activeResolveTask = Task { await resolveAndLoad(name: name, path: path, expectedCodec: nil) }
        case .onchain(let app, let path):
            ensStatus = .fetchingOnchain(app: app, url: browserURL.url)
            activeResolveTask = Task { await fetchAndLoadOnchain(app: app, path: path) }
        }
    }

    // MARK: - Contract-hosted apps

    /// Fetch `html()` with provenance, gate an unverified answer, and
    /// hand the exact bytes to the scheme handler before WebKit loads
    /// the app's canonical origin. Mirrors `resolveAndLoad`.
    private func fetchAndLoadOnchain(app: OnchainAppRef, path: String) async {
        var handedToWebView = false
        defer { if !handedToWebView { endRefreshing() } }

        guard web3Handler != nil else {
            ensStatus = .failed(message: "Onchain apps can't open in a popup tab. Open the link in a new tab.")
            return
        }
        let document: OnchainAppDocument
        do {
            document = try await onchainLoader.load(app)
        } catch {
            if Task.isCancelled { return }
            ensStatus = .failed(message: ENSErrorFormatting.describe(error))
            return
        }
        if Task.isCancelled { return }
        let target = app.canonicalURL(tail: path)
        if document.provenance.hasConflict {
            ensStatus = .idle
            pendingGate = .conflictOnchain(document: document, url: target)
            return
        }
        if !document.provenance.isTrusted, !OnchainApprovals.shared.isApproved(document.provenance) {
            // Withhold the load — and the shield — until the user opts
            // in to exactly these bytes.
            ensStatus = .idle
            pendingGate = .unverifiedOnchain(document: document, url: target)
            return
        }
        ensStatus = .idle
        handedToWebView = true
        loadOnchain(document, url: target)
    }

    private func loadOnchain(_ document: OnchainAppDocument, url: URL) {
        web3Handler?.stage(document)
        chainPin.chainID = document.app.chainID
        currentTrust = document.provenance.trust
        currentOnchain = document.provenance
        loadInWebView(url)
    }

    /// Whether the scheme handler can serve `url` right now. The
    /// navigation delegate lets such loads through (our own load,
    /// back/forward, in-app links) and routes everything else through
    /// `navigate(to:)` so it is fetched and gated first.
    fileprivate func hasStagedOnchainDocument(for url: URL) -> Bool {
        web3Handler?.hasStagedDocument(for: url) ?? false
    }

    var isOnchainApp: Bool {
        url?.scheme?.lowercased() == OnchainAppRef.scheme
    }

    /// Single chokepoint for `webView.load`. Syncs adblock state to the
    /// new top URL synchronously beforehand — otherwise the first batch
    /// of subresources can be blocked under the previous tab's allowlist
    /// state. The KVO observer on `webView.url` catches subsequent
    /// changes (redirects, anchor clicks, pushState).
    private func loadInWebView(_ url: URL) {
        adblock.updateURL(url, for: contentController)
        webView.load(URLRequest(url: url))
    }

    /// Kicks off a Rust-side preload for `ipfs://` / `ipns://`
    /// top-level loads. The reader resolves providers, fetches root
    /// blocks, and warms the cache in parallel with WebKit's request,
    /// so the scheme-handler request typically hits a hot block tree.
    /// Replaces any in-flight preload (one per tab); the previous
    /// task is cancelled.
    ///
    /// Triggered from `WKNavigationDelegate.decidePolicyFor` rather
    /// than from `loadInWebView` — that's the earliest hook that sees
    /// every main-frame navigation, including WebKit-initiated ones
    /// (in-page link clicks, JS-driven `location.href` assignments,
    /// pushState navigations) which never reach `loadInWebView`.
    /// Address-bar / ENS / tab-restore loads also flow through
    /// `decidePolicyFor` (as `.other` navigation type) so coverage
    /// is preserved without a second trigger site.
    fileprivate func triggerIpfsPreload(for url: URL) {
        cancelActivePreload()
        guard let gatewayPath = IpfsSchemeHandler.gatewayStylePath(for: url) else { return }
        let id = ipfs.preload(path: gatewayPath)
        activePreloadID = id
    }

    /// Begin a top-level navigation context for the scheme handler's
    /// correlation-header stamping. Called from
    /// `WKNavigationDelegate.decidePolicyFor` on every main-frame
    /// `ipfs://` / `ipns://` navigation, alongside the preload
    /// trigger.
    fileprivate func beginIpfsNavContext(for url: URL) {
        guard let path = IpfsSchemeHandler.gatewayStylePath(for: url) else { return }
        ipfsNavContext.begin(topLevelPath: path)
        if activeIpfsTopLevelPath != path {
            activeIpfsTopLevelPath = path
        }
    }

    fileprivate func endIpfsNavContext() {
        ipfsNavContext.end()
        if activeIpfsTopLevelPath != nil {
            activeIpfsTopLevelPath = nil
        }
    }

    /// Pre-streaming loading-label for the URL pill, derived from the
    /// Rust gateway's progress snapshot. Returns `nil` outside of an
    /// `ipfs://` / `ipns://` navigation, and once the root request
    /// reaches a terminal phase (streaming / completed / failed /
    /// cancelled — at that point the existing fractional bar or the
    /// page's own error UI is the right thing to show). Otherwise
    /// returns a phase-derived display string using the mapping
    /// documented in `freedom-ipfs/docs/mobile-progress-api.md`.
    var ipfsLoadingLabel: String? {
        guard let topLevelPath = activeIpfsTopLevelPath else { return nil }
        guard let snapshot = ipfs.progressSnapshot else {
            return IpfsProgressPhaseDisplay.fallbackText
        }
        // Prefer the root request (path matches the top-level path).
        // Once the root completes and drops out of `active`, fall
        // back to any active item the gateway has stamped with our
        // navigation's `top_level_path` — those are subresources
        // (CSS / JS / images) of the same page, and surfacing their
        // phase keeps the pill informative through the whole load.
        let target = snapshot.active.first { $0.path == topLevelPath }
            ?? snapshot.active.first { $0.topLevelPath == topLevelPath }
        guard let target, let phase = target.phase else {
            return IpfsProgressPhaseDisplay.fallbackText
        }
        if IpfsProgressPhaseDisplay.isTerminal(phase) {
            return nil
        }
        return target.displayPhase ?? IpfsProgressPhaseDisplay.fallbackText
    }

    /// Unified loading-pill text that surfaces whichever step is
    /// currently in flight. ENS name resolution wins when active —
    /// IPFS hasn't started yet at that point. After ENS finishes
    /// (or for non-ENS navigations) this delegates to the IPFS
    /// gateway's reported phase. Returns `nil` when the page is
    /// idle / fully rendered, hiding the pill entirely.
    var loadingState: String? {
        switch ensStatus {
        case .resolving(let name, _):
            return "Resolving \(name)…"
        case .fetchingOnchain(let app, _):
            return "Fetching app \(app.shortLabel) from chain…"
        case .idle, .failed:
            return ipfsLoadingLabel
        }
    }

    fileprivate func cancelActivePreload() {
        guard activePreloadID != 0 else { return }
        _ = ipfs.cancelPreload(taskID: activePreloadID)
        activePreloadID = 0
    }

    /// Single chokepoint for tearing down the per-navigation IPFS
    /// state — preload + correlation context. Keeps the two coupled
    /// so a future failure callback can't cancel the preload but
    /// forget to end the context (or vice versa).
    fileprivate func tearDownActiveIpfsNavigation() {
        cancelActivePreload()
        endIpfsNavContext()
    }

    private func resetENSState() {
        ensStatus = .idle
        currentTrust = nil
        currentOnchain = nil
        pendingGate = nil
        chainPin.chainID = nil
    }

    /// One-shot bypass of the current unverified gate. Conflict and
    /// anchorDisagreement gates deliberately don't expose this.
    func continuePastGate() {
        switch pendingGate {
        case .unverifiedUntrusted(let url, let trust):
            pendingGate = nil
            ensStatus = .idle
            currentTrust = trust
            // A gate raised by a history re-verification sits over the
            // restored page, which is already showing: reloading it would
            // push a duplicate history entry. Only load what isn't there.
            if webView.url != url { loadInWebView(url) }
        case .unverifiedOnchain(let document, let url):
            // Remembered for this chain + contract + exact hash for the
            // rest of the process; different bytes warn again.
            OnchainApprovals.shared.approve(document.provenance)
            pendingGate = nil
            ensStatus = .idle
            loadOnchain(document, url: url)
        case .codecMismatch(let name, let path, _, _):
            pendingGate = nil
            navigate(to: .ens(name: name, path: path, codec: nil))
        case .conflict, .anchorDisagreement, .conflictOnchain, nil:
            return
        }
    }

    /// Re-run the gated navigation — the onchain conflict gate's "Try
    /// again": a fresh fetch through the same ladder, which resolves an
    /// honest reorg on its own and re-gates a persistent disagreement.
    func retryGatedNavigation() {
        guard case .conflictOnchain(let document, _) = pendingGate else { return }
        pendingGate = nil
        navigate(to: .onchain(app: document.app, path: document.app.canonicalURL(tail: "").path))
    }

    func dismissGate() {
        // Gated ENS state belongs to the rejected navigation — clear it
        // before restoring the prior page so the address bar reflects
        // what's actually on screen (whether that's the prior webview
        // content or the home page).
        pendingGate = nil
        ensStatus = .idle
        currentTrust = nil
        if webView.canGoBack {
            webView.goBack()
        } else {
            hasNavigated = false
        }
    }

    func goBack()    { webView.goBack() }
    func goForward() { webView.goForward() }

    /// Occurrences of `query` in the page's rendered text — the number
    /// the address bar's "On This Page" row shows while typing. Zero
    /// before the tab has loaded anything or when the script fails.
    func countMatches(_ query: String) async -> Int {
        guard hasNavigated, query.count >= FindInPage.minimumQueryLength else { return 0 }
        let result = try? await webView.evaluateJavaScript(FindInPage.countScript(for: query))
        return (result as? NSNumber)?.intValue ?? 0
    }

    /// Hand a typed term to the system find navigator: it opens already
    /// searching, first match highlighted, arrows for the rest, Done to
    /// leave (Safari's "On This Page" flow).
    func startFind(_ query: String) {
        guard hasNavigated, let interaction = webView.findInteraction else { return }
        isFinding = true
        // Safari keeps the keyboard up in find mode so the term can be
        // edited in place. The address bar has just resigned; presenting
        // in the same run loop races its keyboard dismissal and the
        // navigator's search field loses first responder. Let the
        // dismissal settle, then present — the field takes focus and the
        // keyboard returns with the navigator on top of it.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, isFinding else { return }
            interaction.searchText = query
            interaction.presentFindNavigator(showingReplace: false)
            interaction.findNext()
            self.watchFindNavigator()
        }
    }

    private func watchFindNavigator() {
        // UIFindInteraction has no host callback for Done; watch the
        // navigator's visibility so the chrome returns when it closes.
        findWatchTask?.cancel()
        findWatchTask = Task { [weak self] in
            // Give the presentation a moment before the first check.
            try? await Task.sleep(nanoseconds: 500_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                if webView.findInteraction?.isFindNavigatorVisible != true {
                    isFinding = false
                    return
                }
            }
        }
    }

    /// A navigation ends any find session (highlights would be stale).
    func endFind() {
        findWatchTask?.cancel()
        findWatchTask = nil
        webView.findInteraction?.dismissFindNavigator()
        isFinding = false
    }
    /// Re-resolves ENS-origin pages so a rotated content-hash is picked up;
    /// otherwise delegates to WKWebView.reload which re-fetches the current URL.
    /// The handler's own ENS cache would honor `webView.reload()` until its
    /// TTL expires — routing through `navigate(.ens)` forces a fresh
    /// resolve every time, matching the "pull-to-refresh = bypass cache"
    /// contract.
    func reload() {
        // `classify` rewrites any `.eth`-host URL — regardless of codec
        // scheme — to `.ens(name:, path:)` so the path survives the
        // re-resolve. Without `classify`, `bzz://vitalik.eth/blog`
        // would lose `/blog` on pull-to-refresh.
        switch url.flatMap(BrowserURL.classify) {
        case .ens(_, _, _)?, .tez(_, _)?, .onchain(_, _)?:
            // Onchain apps re-fetch `html()` too, so a redeployed
            // contract (or changed bytes) is picked up and re-gated.
            navigate(to: BrowserURL.classify(url!)!)
        default:
            webView.reload()
        }
    }
    func stop() {
        activeResolveTask?.cancel()
        cancelActivePreload()
        webView.stopLoading()
    }

    /// Tab is closing (TabStore.close) — release its subscription
    /// pipelines; the registry outlives the tab. Not part of `stop()`
    /// because the toolbar stop-loading button also calls that, and a
    /// stopped-but-alive page keeps its subscriptions per the SWIP.
    func teardownSwarmSubscriptions() {
        swarmBridge?.cancelSubscriptions()
        // Same lifecycle point for radicle: unhook the tab's seed-status
        // relay from the session-scoped tracker.
        radicleBridge?.detach()
    }

    /// Render the current webview contents at a reduced width as JPEG bytes.
    /// Used for persisting tab thumbnails.
    func snapshot() async -> Data? {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 600
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            webView.takeSnapshot(with: config) { image, _ in
                cont.resume(returning: image?.jpegData(compressionQuality: 0.7))
            }
        }
    }

    /// Thumbnail for a tab whose web view is not on screen (opened in
    /// the background). WebKit paints only views that are in a window,
    /// so the view is parked behind the app's root view for a moment,
    /// snapshotted, and taken out again — unless it was mounted by the
    /// tab becoming active meanwhile, in which case it is left alone.
    func snapshotOffscreen() async -> Data? {
        if webView.window != nil { return await snapshot() }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow)
        else { return nil }
        webView.frame = window.bounds
        window.insertSubview(webView, at: 0)
        window.layoutIfNeeded()
        try? await Task.sleep(nanoseconds: 400_000_000)
        let data = await snapshot()
        if webView.superview === window { webView.removeFromSuperview() }
        return data
    }

    /// `expectedCodec` is the transport the user typed or clicked
    /// (`bzz://name.eth`); a resolution on another codec gates instead
    /// of silently switching schemes (desktop parity; the scheme
    /// handlers enforce the same rule for subresource fetches).
    private func resolveAndLoad(name: String, path: String, expectedCodec: ENSContentCodec?) async {
        // Paths that never reach webView.load (gates, resolve failures,
        // unsupported codecs, task cancellation) need to stop the pull
        // spinner explicitly; the webview-load path rides the isLoading
        // observer instead.
        var handedToWebView = false
        defer { if !handedToWebView { endRefreshing() } }

        let result: ENSResolvedContent
        do {
            switch try await ensResolver.resolveName(name) {
            case .content(let content):
                result = content
            case .web(let target, _):
                // A Tezos Domains HTTP(S) website record: navigate to it
                // directly, as desktop does; the page is ordinary web.
                if Task.isCancelled { return }
                ensStatus = .idle
                currentTrust = nil
                handedToWebView = true
                loadInWebView(target)
                return
            }
        } catch ENSResolutionError.conflict(let groups, let trust) {
            if Task.isCancelled { return }
            ensStatus = .idle
            pendingGate = .conflict(groups: groups, trust: trust)
            return
        } catch ENSResolutionError.anchorDisagreement(let largest, let total, let threshold) {
            if Task.isCancelled { return }
            ensStatus = .idle
            pendingGate = .anchorDisagreement(
                largestBucketSize: largest, total: total, threshold: threshold
            )
            return
        } catch {
            if Task.isCancelled { return }
            ensStatus = .failed(message: ENSErrorFormatting.describe(error))
            return
        }
        if Task.isCancelled { return }
        // Typed scheme is an assertion: `bzz://vitalik.eth` on an IPFS
        // contenthash stops here with "resolves to ipfs, not bzz" and a
        // one-tap way through on the resolved transport.
        if let expectedCodec, result.codec != expectedCodec {
            ensStatus = .idle
            pendingGate = .codecMismatch(name: name, path: path, requested: expectedCodec, resolved: result.codec)
            return
        }
        let finalURL = Self.appendingPath(path, to: result.uri)
        if result.trust.level == .unverified, settings.blockUnverifiedEns {
            // Withhold the webview load until the user opts in. Also
            // withhold currentTrust — the shield shouldn't claim
            // anything yet. continuePastGate sets it when the user proceeds.
            ensStatus = .idle
            pendingGate = .unverifiedUntrusted(url: finalURL, trust: result.trust)
            return
        }
        ensStatus = .idle
        currentTrust = result.trust
        handedToWebView = true
        loadInWebView(finalURL)
    }

    /// Reattach the source URL's path/query/fragment (captured by
    /// `BrowserURL.classify` as a percent-encoded tail) to the resolved
    /// `<codec>://name` URI. Empty path returns `base` unchanged so a
    /// bare-name navigation doesn't grow a trailing slash that previous
    /// `loadInWebView(result.uri)` calls did not produce — keeps URL
    /// identity stable across the patch for HistoryStore dedup.
    ///
    /// URLComponents-based reassembly (over string concat) is load-bearing:
    /// `ENSResolver.doResolveContent` deliberately uses URLComponents to
    /// build `result.uri` because ENSIP-15 normalization can produce
    /// non-ASCII hosts (emoji.eth, IDN labels) that `URL(string:)` rejects.
    /// Round-tripping through `URL(string: "\(scheme)://\(host)\(path)")`
    /// would lose that handling and silently drop the path on non-ASCII
    /// names via the `?? base` fallback.
    private static func appendingPath(_ path: String, to base: URL) -> URL {
        if path.isEmpty { return base }
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        let (pathPart, queryPart, fragmentPart) = Self.splitTail(path)
        comps.percentEncodedPath = pathPart.hasPrefix("/") ? pathPart : "/" + pathPart
        comps.percentEncodedQuery = queryPart
        comps.percentEncodedFragment = fragmentPart
        return comps.url ?? base
    }

    /// Pull the packed `/path?query#fragment` tail back into its three
    /// URLComponents pieces. Mirrors how `BrowserURL.extractTail` glued
    /// them together at classify time.
    private static func splitTail(_ tail: String) -> (path: String, query: String?, fragment: String?) {
        var rest = tail[...]
        let fragment: String?
        if let hashIdx = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: hashIdx)...])
            rest = rest[..<hashIdx]
        } else {
            fragment = nil
        }
        let query: String?
        if let qIdx = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: qIdx)...])
            rest = rest[..<qIdx]
        } else {
            query = nil
        }
        return (String(rest), query, fragment)
    }

    private func observeWebView() {
        // WKWebView posts KVO on the main thread, so these closures execute
        // on the same actor as BrowserTab. Use assumeIsolated to mutate state
        // without bouncing through Task { @MainActor in … }. Writes are
        // guarded by value-change checks because @Observable invalidates
        // downstream views on every setter call regardless of the new value.
        observations.append(webView.observe(\.url, options: .new) { [weak self] wv, _ in
            MainActor.assumeIsolated {
                guard let self, self.url != wv.url else { return }
                self.url = wv.url
                // Redundant for `loadInWebView`-initiated loads (host already
                // matches and updateURL early-returns); required for
                // redirects, anchor clicks, and pushState.
                self.adblock.updateURL(wv.url, for: self.contentController)
                // Leaving a `web3:` origin (link out to https, etc.)
                // ends the app: no pinned chain, no app provenance, no
                // shield claiming the new page was fetched from chain.
                if wv.url?.scheme?.lowercased() != OnchainAppRef.scheme, self.currentOnchain != nil {
                    self.currentOnchain = nil
                    self.currentTrust = nil
                    self.chainPin.chainID = nil
                }
            }
        })
        observations.append(webView.observe(\.title, options: .new) { [weak self] wv, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let new = wv.title ?? ""
                guard self.title != new else { return }
                self.title = new
            }
        })
        observations.append(webView.observe(\.estimatedProgress, options: .new) { [weak self] wv, _ in
            MainActor.assumeIsolated {
                guard let self, abs(self.progress - wv.estimatedProgress) >= 0.01 else { return }
                self.progress = wv.estimatedProgress
            }
        })
        observations.append(webView.observe(\.canGoBack, options: .new) { [weak self] wv, _ in
            MainActor.assumeIsolated {
                guard let self, self.canGoBack != wv.canGoBack else { return }
                self.canGoBack = wv.canGoBack
            }
        })
        observations.append(webView.observe(\.canGoForward, options: .new) { [weak self] wv, _ in
            MainActor.assumeIsolated {
                guard let self, self.canGoForward != wv.canGoForward else { return }
                self.canGoForward = wv.canGoForward
            }
        })
        observations.append(webView.observe(\.isLoading, options: .new) { [weak self] wv, _ in
            MainActor.assumeIsolated {
                guard let self, self.isLoading != wv.isLoading else { return }
                self.isLoading = wv.isLoading
                // Every webview-phase termination (didFinish, didFail,
                // didFailProvisionalNavigation, stopLoading) flips isLoading
                // back to false — one hook covers them all.
                if !wv.isLoading { self.endRefreshing() }
            }
        })
        observations.append(webView.scrollView.observe(\.contentOffset, options: .new) { [weak self] sv, _ in
            MainActor.assumeIsolated {
                self?.handleScroll(scrollView: sv)
            }
        })
    }

    /// Threshold below which the chrome stays expanded — covers
    /// rubber-banding past the top edge plus a small dead zone so the
    /// user doesn't bounce-shrink the chrome from the home position.
    private static let chromeCompactTopThreshold: CGFloat = 8

    /// Movement (in points) the user has to scroll in the current
    /// direction before we toggle the chrome state. Avoids flapping
    /// from tiny accidental drags.
    private static let chromeCompactDeltaThreshold: CGFloat = 10

    /// Best-effort detection of fixed/sticky bottom UI on the page.
    /// Approximates Safari's "reserve space for the page's nav bar"
    /// behavior — true Safari uses a private layout-negotiation
    /// system; we fake it by scanning likely candidate elements (nav,
    /// footer, body's direct children, role="navigation") for
    /// fixed/sticky positioning that lands near the bottom edge with
    /// meaningful size.
    ///
    /// SPAs (React/Vue/Svelte) often render `<body><div id="app"/>`
    /// in the initial HTML and mount their UI after `didFinish` —
    /// so the probe is re-run at increasing delays. The schedule is
    /// cancelled on the next navigation so a slow page doesn't
    /// override a faster subsequent one.
    fileprivate func detectBottomChromeMode() {
        bottomChromeProbeTask?.cancel()
        bottomChromeProbeTask = Task { @MainActor [weak self] in
            await self?.probeBottomChromeOnce()
            for delayMs in [400, 1200, 2500] {
                try? await Task.sleep(for: .milliseconds(delayMs))
                if Task.isCancelled { return }
                await self?.probeBottomChromeOnce()
            }
        }
    }

    fileprivate func cancelBottomChromeProbe() {
        bottomChromeProbeTask?.cancel()
        bottomChromeProbeTask = nil
    }

    /// Wipe per-page chrome surface state at navigation start so the
    /// next page renders against fresh defaults — previous theme
    /// color, sampled nav color, or layout-mode result can't bleed
    /// into the new page. Sibling to `resetENSState()`.
    fileprivate func resetPerPageSurfaceState() {
        themeColor = nil
        bottomChromeMode = .overlay
        bottomNavColor = nil
        cancelBottomChromeProbe()
    }

    private func probeBottomChromeOnce() async {
        // Hit-test the bottom-center pixel of the viewport, then walk
        // up the ancestor chain until we either find a container that
        // looks like a nav bar (substantial height/width, anchored to
        // the bottom edge) or fall through to body. This catches
        // bottom UI regardless of CSS positioning — `position: fixed`,
        // `sticky`, OR a flex-column layout where the nav is just the
        // last child of a viewport-sized container (a common Vue/React
        // pattern that the previous position-only heuristic missed).
        //
        // When a match is found, also sample the effective background
        // color (walking up if the matched element is transparent) so
        // the native chrome can paint its region in the same color —
        // Safari's seamless-extension trick.
        let js = """
        (function() {
            var vh = window.innerHeight;
            var vw = window.innerWidth;
            if (vh < 200 || vw < 200) return null;
            var probeY = vh - 30;
            var el = document.elementFromPoint(vw / 2, probeY);
            if (!el || el === document.body || el === document.documentElement) return null;
            var transparent = /^rgba?\\([^)]+,\\s*0(?:\\.0+)?\\s*\\)$/;
            var maxNavHeight = vh * 0.25;
            while (el && el !== document.body && el !== document.documentElement) {
                var r = el.getBoundingClientRect();
                var anchoredBottom = r.bottom >= vh - 60 && r.bottom <= vh + 20;
                var navSized = r.height >= 40 && r.height <= maxNavHeight && r.width >= vw * 0.5;
                if (anchoredBottom && navSized) {
                    if (el.querySelector('a, button, [role="button"], [role="tab"], [role="link"]')) {
                        var bgEl = el;
                        var bgColor = null;
                        while (bgEl && bgEl !== document.documentElement) {
                            var bg = window.getComputedStyle(bgEl).backgroundColor;
                            if (bg && bg !== 'transparent' && !transparent.test(bg)) {
                                bgColor = bg;
                                break;
                            }
                            bgEl = bgEl.parentElement;
                        }
                        return { hasBottomUI: true, bgColor: bgColor };
                    }
                }
                el = el.parentElement;
            }
            return null;
        })()
        """
        let result = try? await webView.evaluateJavaScript(js)
        // Bail if the navigation cycled out from under us — the JS we
        // just ran is for a page we've since left, and writing its
        // result would override the new page's reset-to-`.overlay`.
        if Task.isCancelled { return }
        let dict = result as? [String: Any]
        let hasBottomUI = (dict?["hasBottomUI"] as? Bool) ?? false
        let nextMode: BottomChromeMode = hasBottomUI ? .reserved : .overlay
        let nextColor = (dict?["bgColor"] as? String).flatMap(UIColor.init(cssRGB:))
        if bottomChromeMode != nextMode { bottomChromeMode = nextMode }
        if bottomNavColor != nextColor { bottomNavColor = nextColor }
    }

    /// Reads the page's `<meta name="theme-color">` after navigation
    /// commits and stores the parsed `UIColor` for the top-safe-area
    /// background. Honors media-conditional tags — pages can ship
    /// separate light/dark colors via
    /// `<meta name="theme-color" content="..." media="(prefers-color-scheme: dark)">`
    /// and we pick the first whose media query matches; falls back to
    /// the no-`media` tag. Hex-only parser; non-hex values
    /// (rgb/hsl/named) are silently ignored so we fall back to nil.
    fileprivate func extractThemeColor() {
        let js = """
        (function() {
            var metas = document.querySelectorAll('meta[name="theme-color"]');
            var fallback = null;
            for (var i = 0; i < metas.length; i++) {
                var media = metas[i].getAttribute('media');
                if (!media) {
                    fallback = metas[i].content;
                } else if (window.matchMedia(media).matches) {
                    return metas[i].content;
                }
            }
            return fallback;
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            let color = (result as? String).flatMap(UIColor.init(hex:))
            // KVO/JS callback arrives on main; set the @Observable
            // property directly. assumeIsolated mirrors the surrounding
            // observer style.
            MainActor.assumeIsolated {
                if self.themeColor != color { self.themeColor = color }
            }
        }
    }

    private func handleScroll(scrollView: UIScrollView) {
        let y = scrollView.contentOffset.y
        // Near the top — always expanded. Catches both fresh-load and
        // pull-to-refresh / rubber-band overscroll.
        if y < Self.chromeCompactTopThreshold {
            if chromeIsCompact { chromeIsCompact = false }
            lastScrollY = y
            return
        }
        // Programmatic scrolls (WKWebView restoring a remembered offset
        // on back-nav, anchor jumps, JS scrollTo) shouldn't flip the
        // chrome — only user-driven drags / their decelerations should.
        // Keep the anchor in sync so the next real drag still sees a
        // sensible delta.
        guard scrollView.isDragging || scrollView.isDecelerating else {
            lastScrollY = y
            return
        }
        let delta = y - lastScrollY
        if delta > Self.chromeCompactDeltaThreshold {
            if !chromeIsCompact { chromeIsCompact = true }
            lastScrollY = y
        } else if delta < -Self.chromeCompactDeltaThreshold {
            if chromeIsCompact { chromeIsCompact = false }
            lastScrollY = y
        }
        // Within the dead zone — keep state, leave the anchor alone so
        // small jitters don't slowly drift the threshold past us.
    }
}

/// Bridges WebKit's window-management callbacks to the tab layer. Without
/// a `WKUIDelegate` implementing `createWebViewWith`, `window.open` (and
/// `target="_blank"`) returns null in every page and no navigation happens
/// — dapps that open editors/viewers in new tabs silently degrade to
/// same-tab fallbacks. The actual tab creation lives in TabStore (it owns
/// the service dependencies); this just forwards.
private final class UIDelegate: NSObject, WKUIDelegate {
    weak var owner: BrowserTab?

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        MainActor.assumeIsolated {
            // Contract-hosted apps get no page-created windows (desktop
            // parity; the CSP sandbox already denies popups, this is
            // the belt to its braces).
            if owner?.isOnchainApp == true { return nil }
            // `target="_blank"` onto an `ethereum:` payment link: the
            // wallet's Send form, not a tab.
            if let url = navigationAction.request.url, url.scheme?.lowercased() == EthereumURI.scheme {
                owner?.onEthereumURI?(url)
                return nil
            }
            // `target="_blank"` onto mailto:/tel:/an app scheme: consent
            // and the system, not a tab.
            if let url = navigationAction.request.url, ExternalLinks.isExternal(url) {
                owner?.requestExternalOpen(url)
                return nil
            }
            return owner?.onCreatePopup?(configuration)
        }
    }

    /// Only fires for pages WebKit itself opened via `createWebViewWith`
    /// (`window.close()` is a no-op for user-opened tabs) — so closing
    /// the tab here can't be triggered by arbitrary tabs.
    func webViewDidClose(_ webView: WKWebView) {
        MainActor.assumeIsolated { owner?.onRequestClose?() }
    }

    /// Long-press on a link: a preview of the target plus our actions.
    /// Without this WebKit shows its own preview with Open / Copy / Share
    /// (or nothing at all when the page opts out) — this is the desktop
    /// link + image context menu.
    func webView(
        _ webView: WKWebView,
        contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
    ) {
        guard let link = elementInfo.linkURL else { completionHandler(nil); return }
        MainActor.assumeIsolated {
            guard let owner else { completionHandler(nil); return }
            Task { @MainActor in
                let touched = await owner.touchedElement()
                let configuration = webView.configuration
                let config = UIContextMenuConfiguration(identifier: nil, previewProvider: {
                    LinkPreviewController(url: link, configuration: configuration)
                }, actionProvider: { _ in
                    var items: [UIMenuElement] = [
                        UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.square.on.square")) { _ in
                            owner.onOpenInNewTab?(link, false)
                        },
                        UIAction(title: "Open in Background", image: UIImage(systemName: "square.on.square")) { _ in
                            owner.onOpenInNewTab?(link, true)
                        },
                        UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in
                            owner.copyToPasteboard(link)
                        },
                        UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                            owner.share(link)
                        },
                    ]
                    if let image = touched.image {
                        var imageItems: [UIMenuElement] = [
                            UIAction(title: "Open Image in New Tab", image: UIImage(systemName: "photo")) { _ in
                                owner.onOpenInNewTab?(image, false)
                            },
                            UIAction(title: "Copy Image Address", image: UIImage(systemName: "link")) { _ in
                                owner.copyToPasteboard(image)
                            },
                        ]
                        if ContextMenuSupport.canSaveImage(image) {
                            imageItems.append(UIAction(title: "Save Image", image: UIImage(systemName: "square.and.arrow.down")) { _ in
                                owner.saveImage(image)
                            })
                        }
                        items.append(UIMenu(title: "", options: .displayInline, children: imageItems))
                    }
                    return UIMenu(title: link.absoluteString, children: items)
                })
                completionHandler(config)
            }
        }
    }

    /// Tapping the preview opens the link in this tab, through the same
    /// path a link click takes (ENS resolution and gates included).
    func webView(
        _ webView: WKWebView,
        contextMenuForElement elementInfo: WKContextMenuElementInfo,
        willCommitWithAnimator animator: UIContextMenuInteractionCommitAnimating
    ) {
        guard let link = elementInfo.linkURL else { return }
        animator.addCompletion {
            MainActor.assumeIsolated {
                guard let owner = self.owner else { return }
                if let browserURL = BrowserURL.classify(link) {
                    owner.navigate(to: browserURL)
                } else {
                    owner.onOpenInNewTab?(link, false)
                }
            }
        }
    }

    /// getUserMedia: camera / microphone. Without this hook WebKit shows
    /// its own per-origin system prompt; with it, Freedom's prompt,
    /// remembered decisions and revocation apply (desktop parity).
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        MainActor.assumeIsolated {
            owner?.requestSitePermission(
                origin: SitePermissionStore.origin(for: origin),
                kinds: SitePermissionKind.kinds(for: type)
            ) { decisionHandler($0 == .allow ? .grant : .deny) }
        }
    }

    /// DeviceMotion / DeviceOrientation events.
    func webView(
        _ webView: WKWebView,
        requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        MainActor.assumeIsolated {
            owner?.requestSitePermission(
                origin: SitePermissionStore.origin(for: origin), kinds: [.motion]
            ) { decisionHandler($0 == .allow ? .grant : .deny) }
        }
    }
}

private final class NavDelegate: NSObject, WKNavigationDelegate {
    weak var owner: BrowserTab?

    /// Earliest navigation hook — fires before WebKit issues the
    /// request, on every main-frame navigation regardless of how it
    /// started (address bar via `webView.load`, ENS resolution, tab
    /// restore, in-page link click, JS `location.href`, history
    /// nav, reload). For `ipfs://` / `ipns://` we use it to warm
    /// the Rust reader's routing/blocks ahead of the scheme handler
    /// being asked, and to publish a navigation context the scheme
    /// handler stamps onto correlation headers.
    ///
    /// Also the chokepoint for redirecting user-initiated `.eth`-host
    /// navigations through `BrowserTab.navigate` so the trust shield
    /// and `blockUnverifiedEns` / conflict / anchorDisagreement gates
    /// apply to in-page link clicks — without this, the scheme handlers
    /// resolve ENS internally but discard the trust object.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // `<a download>` and other explicit download requests.
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        // An EIP-681 payment link: never a page load, the wallet's Send
        // form (desktop parity). `ethereum` counts as a browser scheme so
        // it never reaches the external-app prompt below.
        if let url = navigationAction.request.url, url.scheme?.lowercased() == EthereumURI.scheme {
            decisionHandler(.cancel)
            MainActor.assumeIsolated { owner?.onEthereumURI?(url) }
            return
        }
        // A scheme the browser cannot show: never a navigation, an ask.
        if let url = navigationAction.request.url, ExternalLinks.isExternal(url) {
            decisionHandler(.cancel)
            MainActor.assumeIsolated { owner?.requestExternalOpen(url) }
            return
        }
        if let url = navigationAction.request.url,
           navigationAction.targetFrame?.isMainFrame == true,
           Self.shouldInterceptForENS(navigationAction.navigationType),
           !Self.isSameDocumentFragmentNav(target: url, current: webView.url),
           let browserURL = BrowserURL.classify(url),
           browserURL.isName
        {
            decisionHandler(.cancel)
            MainActor.assumeIsolated { owner?.navigate(to: browserURL) }
            return
        }
        // Back/Forward onto an ENS-backed entry (desktop #86): keep
        // WebKit's history traversal — the entry is restored, not
        // re-navigated — but never restore the verdict from the first
        // visit. The name is re-verified under the current settings and
        // the shield and gates follow the fresh result.
        if let url = navigationAction.request.url,
           navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.navigationType == .backForward,
           let name = BrowserTab.ensNameToReverify(url)
        {
            MainActor.assumeIsolated { owner?.reverifyTrust(name: name, restored: url) }
        }
        // Contract-hosted apps: any main-frame `web3:` load the tab
        // hasn't fetched and staged goes through `navigate(to:)` so it
        // is fetched with provenance and gated first — a link from a
        // web page, a typed friendly URL, a restored history entry, or
        // a script on another origin setting `location`. Loads the tab
        // staged (its own `loadInWebView`, back/forward, in-app links
        // under the same origin) pass straight to the handler.
        if let url = navigationAction.request.url,
           url.scheme?.lowercased() == OnchainAppRef.scheme,
           navigationAction.targetFrame?.isMainFrame == true,
           !Self.isSameDocumentFragmentNav(target: url, current: webView.url),
           let browserURL = BrowserURL.classify(url),
           case .onchain = browserURL
        {
            let staged = MainActor.assumeIsolated { owner?.hasStagedOnchainDocument(for: url) ?? false }
            if !staged {
                decisionHandler(.cancel)
                MainActor.assumeIsolated { owner?.navigate(to: browserURL) }
                return
            }
        }
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           (scheme == "ipfs" || scheme == "ipns"),
           navigationAction.targetFrame?.isMainFrame == true
        {
            MainActor.assumeIsolated {
                owner?.triggerIpfsPreload(for: url)
                owner?.beginIpfsNavContext(for: url)
            }
        }
        decisionHandler(.allow)
    }

    /// True for navigations that originated outside `BrowserTab` and
    /// should be re-routed through the ENS pipeline. `.other` covers
    /// our own `loadInWebView` (the resolved URL coming back through
    /// the policy hook) — re-intercepting it would loop. `.reload`
    /// has its own ENS-aware path in `BrowserTab.reload()`; `.backForward`
    /// restores an already-loaded entry and must not be re-navigated (that
    /// would grow the history stack) — its verdict is refreshed in place
    /// by `reverifyTrust` instead (desktop #86).
    /// `.formSubmitted` / `.formResubmitted` are excluded because
    /// re-issuing the navigation through `webView.load(URLRequest(url:))`
    /// downgrades the POST to a GET and silently drops the form body —
    /// preserving form semantics outweighs the trust-gate coverage for
    /// the rare ENS-host POST.
    private static func shouldInterceptForENS(_ type: WKNavigationType) -> Bool {
        switch type {
        case .linkActivated: return true
        case .formSubmitted, .formResubmitted: return false
        case .backForward, .reload, .other: return false
        @unknown default: return false
        }
    }

    /// True when `target` differs from `current` only in its fragment
    /// (same scheme + host + path + query) — WebKit fires `decidePolicyFor`
    /// for `<a href="#section">` clicks even though the navigation is a
    /// same-document scroll, and re-routing through `navigate(.ens)` would
    /// trigger a redundant ENS resolve + full-page reload, discarding
    /// scroll position and any JS state.
    private static func isSameDocumentFragmentNav(target: URL, current: URL?) -> Bool {
        guard let current, target.fragment != nil else { return false }
        return target.scheme == current.scheme
            && target.host == current.host
            && target.path == current.path
            && target.query == current.query
    }

    /// A response the web view cannot display (or one the server marks
    /// as an attachment) becomes a download — for http(s), the dweb
    /// scheme handlers and data URIs alike (desktop parity).
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if BrowserTab.shouldDownload(navigationResponse) {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        MainActor.assumeIsolated {
            DownloadManager.shared.adopt(
                download, sourceURL: navigationAction.request.url, mimeType: nil, from: webView,
                ephemeral: owner?.isPrivate ?? false
            )
        }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        MainActor.assumeIsolated {
            DownloadManager.shared.adopt(
                download, sourceURL: navigationResponse.response.url,
                mimeType: navigationResponse.response.mimeType, from: webView,
                ephemeral: owner?.isPrivate ?? false
            )
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Fresh EIP-6963 UUID + idempotent swarm preload per page session.
        // Per-page surface state (theme color + bottom chrome mode) is
        // cleared so the chrome reverts to default while loading rather
        // than carrying the previous page's brand color or layout
        // negotiation into a fresh navigation.
        MainActor.assumeIsolated {
            owner?.reinstallPreloads()
            owner?.resetPerPageSurfaceState()
            // A navigation withdraws the departing page's prompts and
            // ends its find session.
            owner?.cancelPermissionPrompts()
            owner?.endFind()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        let title = webView.title ?? ""
        // WKNavigationDelegate callbacks arrive on the main thread, same
        // pattern as the KVO observers in BrowserTab.
        MainActor.assumeIsolated {
            owner?.tearDownActiveIpfsNavigation()
            // History / favicons see the friendly `web3://…` form.
            owner?.onNavigationFinish?(BrowserTab.presented(url), title)
            owner?.extractThemeColor()
            owner?.detectBottomChromeMode()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            owner?.tearDownActiveIpfsNavigation()
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated {
            owner?.tearDownActiveIpfsNavigation()
        }
    }
}

enum ENSErrorFormatting {
    static func describe(_ error: Error) -> String {
        switch error {
        case ENSResolutionError.invalidName:
            return "Invalid ENS name."
        case ENSResolutionError.notFound(.noResolver, _):
            return "This name isn't registered on ENS."
        case ENSResolutionError.notFound(.noContenthash, _), ENSResolutionError.notFound(.emptyContenthash, _):
            return "No content set on this ENS name."
        case ENSResolutionError.notFound(.ccipDisabled, _):
            return "This ENS name resolves via an offchain gateway (CCIP-Read). Enable it in Settings → Advanced to load it."
        case ENSResolutionError.notFound(.emptyAddress, _):
            return "This name has no address record for this network."
        case ENSResolutionError.notSupportedOnChain(let system, _):
            return "\(system.label) names only resolve on Ethereum. Pick Ethereum or enter a 0x address."
        case ENSResolutionError.unsupportedChain:
            return "Name resolution isn't supported on this network."
        case ENSResolutionError.unsupportedCodec(let rawBytes, _):
            // Diagnostic: surface the first few bytes so we can tell which
            // failure mode bit (ABI-unwrap garbage vs. unrecognized codec)
            // and what the resolver actually returned.
            let preview = rawBytes.prefix(40)
                .map { String(format: "%02x", $0) }
                .joined()
            let suffix = rawBytes.count > 40 ? "…" : ""
            return "Unsupported contenthash codec. Got \(rawBytes.count)B: \(preview)\(suffix)"
        case ENSResolutionError.conflict:
            return "RPC providers disagreed on the contenthash — possible attack."
        case ENSResolutionError.anchorDisagreement:
            return "RPC providers disagreed on the anchor block — possible attack."
        case ENSResolutionError.allProvidersErrored:
            return "All Ethereum RPC providers failed. Check your network."
        case ENSResolutionError.customRpcFailed:
            return "Your custom Ethereum RPC is unreachable or invalid. Check Settings → Custom RPC."
        case ENSResolutionError.notImplemented:
            return "ENS resolution not implemented."
        case TezosDomainsError.notFound(let reason):
            return "Tezos Domains: \(reason)."
        case TezosDomainsError.unsupported(let reason):
            return "This .tez name publishes a website record Freedom can't follow (\(reason))."
        case TezosDomainsError.unavailable(let reason):
            return "Couldn't reach the Tezos RPC providers (\(reason)). Check your network."
        case TezosDomainsError.notContent:
            return "This .tez name points at a regular website, not IPFS content."
        case OnchainAppError.unknownChain(let chainID):
            return "Chain \(chainID) isn't in your wallet's chain list. Add it in Wallet → Networks, then try again."
        case OnchainAppError.unreachable:
            return "Couldn't reach any RPC endpoint for this chain to fetch the app."
        case OnchainAppError.notAnApp(let detail):
            return "The contract did not return a valid ERC-8244 html() document on this chain (\(detail))."
        case OnchainAppError.tooLarge:
            return "The app's html() document exceeds Freedom's 8 MiB limit."
        case OnchainAppError.timedOut:
            return "Fetching the app from the chain timed out."
        default:
            return "ENS resolution failed: \(error.localizedDescription)"
        }
    }
}

/// Fetches a feed entry at an exact index by computing the SOC address
/// from `(owner, topic, index)` and reading `/chunks/{socAddress}` —
/// bypassing bee's `/feeds/...?index` epoch-search semantics. The
/// returned chunk's first 105 bytes are the SOC envelope (identifier
/// 32 || sig 65 || span 8); the SOC's payload follows.
///
/// For entries written via the > 4 KB wrap path, the SOC's payload is
/// a BMT-tree root rather than the original bytes. The wrapping is
/// detectable via the SOC's span: if span > 4096, we re-resolve the
/// payload through `/bytes/{cacAddress}` (which bee walks the tree
/// for) to get the dapp's original bytes back.
@MainActor
private func fetchFeedSOC(
    owner: String, topic: String, index: UInt64, bee: BeeAPIClient
) async throws -> SwarmRouter.FeedRead {
    guard let topicBytes = Data(hex: topic), topicBytes.count == 32,
          let ownerBytes = Data(hex: owner), ownerBytes.count == 20 else {
        throw SwarmRouter.FeedReadError.notFound
    }
    let identifier = SwarmSOC.feedIdentifier(topic: topicBytes, index: index)
    let socAddressHex = SwarmSOC.socAddress(
        identifier: identifier, ownerAddress: ownerBytes
    ).web3.hexString.web3.noHexPrefix
    let chunkBytes = try await bee.getChunk(reference: socAddressHex)
    guard chunkBytes.count >= SwarmSOC.socEnvelopeSize else {
        throw SwarmRouter.FeedReadError.notFound
    }

    // SOC layout: identifier(32) || signature(65) || span(8) || payload.
    let spanStart = SwarmSOC.socEnvelopeSize - 8
    let span = chunkBytes.subdata(in: spanStart..<SwarmSOC.socEnvelopeSize)
    let socPayload = chunkBytes.subdata(in: SwarmSOC.socEnvelopeSize..<chunkBytes.count)
    let originalLength = span.withUnsafeBytes { $0.load(as: UInt64.self) }
    // (iOS is LE-native and bee writes span LE, so a direct load gives
    // the right value — `UInt64(littleEndian:)` is intent-doc only.)

    let payload: Data
    if originalLength > UInt64(SwarmSOC.maxChunkPayloadSize) {
        // Wrapped: the SOC payload is a BMT root, not the dapp's bytes.
        // Re-fetch via /bytes/{cacAddress} so bee walks the tree.
        do {
            let cac = try SwarmSOC.makeCAC(span: span, payload: socPayload)
            payload = try await bee.downloadBytes(
                reference: cac.address.web3.hexString.web3.noHexPrefix
            )
        } catch {
            throw SwarmRouter.FeedReadError.notFound
        }
    } else {
        payload = socPayload
    }
    return SwarmRouter.FeedRead(payload: payload, index: index, nextIndex: nil)
}


extension UIViewController {
    /// The controller currently on top of this one's presentation chain.
    var topMostPresented: UIViewController {
        var top: UIViewController = self
        while let next = top.presentedViewController { top = next }
        return top
    }
}
