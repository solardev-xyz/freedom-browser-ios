import Foundation
import Observation
import UIKit
import web3
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
    /// True while the user is scrolling down the page — drives the
    /// Safari-style chrome shrink. Resets to false on scroll-up and
    /// near the top of the page (which also catches fresh navigations,
    /// since contentOffset jumps to 0 on every WebKit commit).
    var chromeIsCompact: Bool = false
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
    var pendingSwarmApproval: ApprovalRequest?

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
    @ObservationIgnored private var lastScrollY: CGFloat = 0
    @ObservationIgnored private let navDelegate = NavDelegate()
    @ObservationIgnored private var activeResolveTask: Task<Void, Never>?
    @ObservationIgnored private let contentController: WKUserContentController
    @ObservationIgnored fileprivate var walletBridge: EthereumBridge?
    @ObservationIgnored fileprivate var swarmBridge: SwarmBridge?

    init(
        recordID: UUID = UUID(),
        ensResolver: ENSResolver,
        settings: SettingsStore,
        wallet: WalletServices,
        swarm: SwarmServices
    ) {
        self.recordID = recordID
        self.ensResolver = ensResolver
        self.settings = settings
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(BzzSchemeHandler(), forURLScheme: "bzz")
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let contentController = WKUserContentController()
        config.userContentController = contentController
        self.contentController = contentController
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
            }
        )
        self.swarmBridge = SwarmBridge(
            tab: self,
            router: swarmRouter,
            contentController: contentController,
            services: swarm
        )

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

    private func handleScroll(scrollView: UIScrollView) {
        let y = scrollView.contentOffset.y
        // Near the top — always expanded. Catches both fresh-load and
        // pull-to-refresh / rubber-band overscroll.
        if y < Self.chromeCompactTopThreshold {
            if chromeIsCompact { chromeIsCompact = false }
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

private final class NavDelegate: NSObject, WKNavigationDelegate {
    weak var owner: BrowserTab?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Fresh EIP-6963 UUID + idempotent swarm preload per page session.
        MainActor.assumeIsolated {
            owner?.reinstallPreloads()
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
