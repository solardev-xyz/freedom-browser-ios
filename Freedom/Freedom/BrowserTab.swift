import Foundation
import Observation
import UIKit
import WebKit

@MainActor
@Observable
final class BrowserTab {
    enum ENSStatus: Equatable {
        case idle
        case resolving(name: String)
        case failed(message: String)
    }

    /// A gated navigation waiting for user consent. Rendered in place of
    /// the webview until the user continues (unverified only) or backs
    /// out (all gates). Conflict and anchorDisagreement are security
    /// signals with no continue option.
    enum Gate: Equatable {
        case unverifiedUntrusted(url: URL, trust: ENSTrust)
        case conflict(groups: [ENSConflictGroup], trust: ENSTrust)
        case anchorDisagreement(largestBucketSize: Int, total: Int, threshold: Int)
    }

    let recordID: UUID

    var url: URL?
    var title: String = ""
    var progress: Double = 0
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var isLoading: Bool = false
    private(set) var hasNavigated: Bool = false

    /// Pseudo-URL for the originating ENS name when the page was loaded
    /// via ENS resolution. Kept alongside `url` (the resolved bzz://
    /// WebKit actually loaded) so the address bar, history and bookmarks
    /// can store the ens:// form — revisits re-resolve and pick up any
    /// content-hash rotation by the ENS record owner.
    var ensURL: URL?
    var ensStatus: ENSStatus = .idle

    /// Trust metadata from the last ENS resolution. The address-bar
    /// shield (M4.10) reads this; nil means the current page wasn't
    /// reached through ENS.
    var currentTrust: ENSTrust?

    /// Non-nil when a navigation is blocked by an interstitial. The UI
    /// renders an ENSInterstitial in place of the webview; the gate is
    /// cleared by dismissGate() or continuePastGate().
    var pendingGate: Gate?

    /// URL the UI presents — ENS form if set, otherwise the live webview URL.
    var displayURL: URL? { ensURL ?? url }

    /// Parked approval. The bridge awaits `ApprovalResolver`; the sheet
    /// presents via ContentView. Call `resolvePendingApproval` from any
    /// dismissal path (tab close, swipe) so the resolver fires exactly once
    /// — `ApprovalResolver` is the fire-once guard.
    var pendingEthereumApproval: ApprovalRequest?

    func resolvePendingApproval(_ decision: ApprovalRequest.Decision) {
        let pending = pendingEthereumApproval
        pendingEthereumApproval = nil
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

    @ObservationIgnored private let ensResolver: ENSResolver
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private let navDelegate = NavDelegate()
    @ObservationIgnored private var activeResolveTask: Task<Void, Never>?
    @ObservationIgnored fileprivate var walletBridge: EthereumBridge?

    init(
        recordID: UUID = UUID(),
        ensResolver: ENSResolver,
        settings: SettingsStore,
        wallet: WalletServices
    ) {
        self.recordID = recordID
        self.ensResolver = ensResolver
        self.settings = settings
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(BzzSchemeHandler(), forURLScheme: "bzz")
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let contentController = WKUserContentController()
        config.userContentController = contentController
        self.webView = WKWebView(frame: .zero, configuration: config)
        self.webView.navigationDelegate = navDelegate
        navDelegate.owner = self

        // Active chain read live so a wallet-UI chain switch is picked up
        // by dapp reads without rebuilding the router.
        let router = RPCRouter(
            registry: wallet.chainRegistry,
            permissionStore: wallet.permissionStore,
            activeChain: {
                let raw = UserDefaults.standard.integer(forKey: WalletDefaults.activeChainID)
                let id = raw == 0 ? Chain.defaultChain.id : raw
                return Chain.find(id: id) ?? .defaultChain
            }
        )
        self.walletBridge = EthereumBridge(
            tab: self,
            router: router,
            contentController: contentController,
            services: wallet
        )

        observeWebView()
        installPullToRefresh()
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
    }

    func navigate(to browserURL: BrowserURL) {
        hasNavigated = true
        activeResolveTask?.cancel()
        resetENSState()
        switch browserURL {
        case .bzz(let target), .web(let target):
            webView.load(URLRequest(url: target))
        case .ens(let name):
            ensURL = browserURL.url
            ensStatus = .resolving(name: name)
            activeResolveTask = Task { await resolveAndLoad(name: name) }
        }
    }

    private func resetENSState() {
        ensURL = nil
        ensStatus = .idle
        currentTrust = nil
        pendingGate = nil
    }

    /// One-shot bypass of the current unverified gate. Conflict and
    /// anchorDisagreement gates deliberately don't expose this.
    func continuePastGate() {
        guard case .unverifiedUntrusted(let url, let trust) = pendingGate else { return }
        pendingGate = nil
        ensStatus = .idle
        currentTrust = trust
        webView.load(URLRequest(url: url))
    }

    func dismissGate() {
        // Gated ENS state belongs to the rejected navigation — clear it
        // before restoring the prior page so the address bar reflects
        // what's actually on screen (whether that's the prior webview
        // content or the home page).
        pendingGate = nil
        ensURL = nil
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
    /// Re-resolves ENS-origin pages so a rotated content-hash is picked up;
    /// otherwise delegates to WKWebView.reload which re-fetches the current URL.
    func reload() {
        if let ensURL, case .ens(let name) = BrowserURL.classify(ensURL) {
            navigate(to: .ens(name: name))
        } else {
            webView.reload()
        }
    }
    func stop() {
        activeResolveTask?.cancel()
        webView.stopLoading()
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

    private func resolveAndLoad(name: String) async {
        // Paths that never reach webView.load (gates, resolve failures,
        // unsupported codecs, task cancellation) need to stop the pull
        // spinner explicitly; the webview-load path rides the isLoading
        // observer instead.
        var handedToWebView = false
        defer { if !handedToWebView { endRefreshing() } }

        let result: ENSResolvedContent
        do {
            result = try await ensResolver.resolveContent(name)
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
        switch result.codec {
        case .ipfs, .ipns:
            ensStatus = .failed(message: "IPFS/IPNS content not yet supported on iOS.")
            return
        case .bzz:
            break
        }
        if result.trust.level == .unverified, settings.blockUnverifiedEns {
            // Withhold the webview load until the user opts in. Also
            // withhold currentTrust — the shield shouldn't claim
            // anything yet. continuePastGate sets it when the user proceeds.
            ensStatus = .idle
            pendingGate = .unverifiedUntrusted(url: result.uri, trust: result.trust)
            return
        }
        ensStatus = .idle
        currentTrust = result.trust
        handedToWebView = true
        webView.load(URLRequest(url: result.uri))
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
    }
}

private final class NavDelegate: NSObject, WKNavigationDelegate {
    weak var owner: BrowserTab?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Fresh EIP-6963 UUID per page session — reinstall the preload.
        MainActor.assumeIsolated {
            owner?.walletBridge?.reinstallForNewNavigation()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        let title = webView.title ?? ""
        // WKNavigationDelegate callbacks arrive on the main thread, same
        // pattern as the KVO observers in BrowserTab.
        MainActor.assumeIsolated {
            owner?.onNavigationFinish?(url, title)
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
            return "This ENS name has no Ethereum address set."
        case ENSResolutionError.unsupportedCodec:
            return "Unsupported contenthash codec."
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
        default:
            return "ENS resolution failed: \(error.localizedDescription)"
        }
    }
}
