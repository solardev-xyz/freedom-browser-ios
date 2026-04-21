import SwiftUI
import WebKit

struct BrowserWebView: UIViewRepresentable {
    let tab: BrowserTab

    func makeUIView(context: Context) -> WKWebView { tab.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
