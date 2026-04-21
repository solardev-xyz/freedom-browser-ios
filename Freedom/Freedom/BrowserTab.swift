import Foundation
import Observation
import UIKit
import WebKit

@MainActor
@Observable
final class BrowserTab {
    let recordID: UUID

    var url: URL?
    var title: String = ""
    var progress: Double = 0
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var isLoading: Bool = false
    private(set) var hasNavigated: Bool = false

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

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private let navDelegate = NavDelegate()

    init(recordID: UUID = UUID()) {
        self.recordID = recordID
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(BzzSchemeHandler(), forURLScheme: "bzz")
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        self.webView = WKWebView(frame: .zero, configuration: config)
        self.webView.navigationDelegate = navDelegate
        navDelegate.owner = self
        observeWebView()
    }

    deinit {
        observations.forEach { $0.invalidate() }
    }

    func navigate(to browserURL: BrowserURL) {
        hasNavigated = true
        webView.load(URLRequest(url: browserURL.url))
    }

    func goBack()    { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload()    { webView.reload() }
    func stop()      { webView.stopLoading() }

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
            }
        })
    }
}

private final class NavDelegate: NSObject, WKNavigationDelegate {
    weak var owner: BrowserTab?

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
