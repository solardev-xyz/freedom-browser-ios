import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class BrowserTab {
    var url: URL?
    var progress: Double = 0
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var isLoading: Bool = false

    let webView: WKWebView

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(BzzSchemeHandler(), forURLScheme: "bzz")
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        self.webView = WKWebView(frame: .zero, configuration: config)
        observeWebView()
    }

    deinit {
        observations.forEach { $0.invalidate() }
    }

    func navigate(to browserURL: BrowserURL) {
        webView.load(URLRequest(url: browserURL.url))
    }

    func goBack()    { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload()    { webView.reload() }
    func stop()      { webView.stopLoading() }

    private func observeWebView() {
        // WKWebView posts KVO on the main thread, so these closures execute
        // on the same actor as BrowserTab. Use assumeIsolated to mutate state
        // without bouncing through Task { @MainActor in … }. Writes are
        // guarded by value-change checks because @Observable invalidates
        // downstream views on every setter call regardless of the new value,
        // and estimatedProgress in particular posts hundreds of times per
        // page load.
        observations.append(webView.observe(\.url, options: .new) { [weak self] wv, _ in
            MainActor.assumeIsolated {
                guard let self, self.url != wv.url else { return }
                self.url = wv.url
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
