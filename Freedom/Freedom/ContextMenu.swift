import UIKit
import WebKit

/// Context menus (desktop parity): long-press on a link opens a preview
/// with Open in New Tab / Open in Background / Copy Link / Share, plus
/// image actions when the link wraps an image; the text-selection edit
/// menu gains "Search <Engine> for “…”". WebKit only tells the host the
/// link URL, so a user script records the element under the last touch
/// (link + image) and relays the current selection.
enum ContextMenuSupport {
    static let selectionHandlerName = "freedomSelection"
    /// Desktop `SEARCH_MENU_SELECTION_MAX`: how much of a selection the
    /// menu item shows before eliding.
    static let selectionMenuMax = 32

    static let touchScriptSource = """
    (() => {
      if (window.__freedomContextMenuInstalled) return;
      window.__freedomContextMenuInstalled = true;
      document.addEventListener('touchstart', (e) => {
        const t = e.target instanceof Element ? e.target : null;
        const a = t && t.closest('a[href]');
        const img = t && t.closest('img');
        window.__freedomTouch = {
          link: a ? a.href : null,
          image: img ? (img.currentSrc || img.src || null) : null
        };
      }, { capture: true, passive: true });
      document.addEventListener('selectionchange', () => {
        try {
          const s = String(window.getSelection() || '');
          window.webkit.messageHandlers.freedomSelection.postMessage(s.slice(0, 500));
        } catch (_) {}
      });
    })();
    """
    static let touchQuery = "window.__freedomTouch || null"

    struct TouchedElement: Equatable {
        var link: URL?
        var image: URL?

        static func parse(_ value: Any?) -> TouchedElement {
            guard let dict = value as? [String: Any] else { return TouchedElement() }
            func url(_ key: String) -> URL? {
                guard let s = dict[key] as? String, !s.isEmpty, let u = URL(string: s), u.scheme != nil else { return nil }
                return u
            }
            return TouchedElement(link: url("link"), image: url("image"))
        }
    }

    /// `Search DuckDuckGo for “…”`, the selection collapsed to one line
    /// and elided past `selectionMenuMax`.
    static func selectionMenuTitle(engine: String, selection: String) -> String? {
        let oneLine = selection.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else { return nil }
        let shown = oneLine.count > selectionMenuMax ? String(oneLine.prefix(selectionMenuMax)) + "…" : oneLine
        return "Search \(engine) for “\(shown)”"
    }

    /// Save Image fetches the bytes itself; only web URLs are fetched.
    static func canSaveImage(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}

/// The long-press preview: the link rendered in its own web view built
/// from the tab's configuration, so dweb schemes preview too.
final class LinkPreviewController: UIViewController {
    private let url: URL
    private let configuration: WKWebViewConfiguration

    init(url: URL, configuration: WKWebViewConfiguration) {
        self.url = url
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 320, height: 480)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsLinkPreview = false
        webView.isUserInteractionEnabled = false
        webView.load(URLRequest(url: url))
        view = webView
    }
}

/// Relays the page's text selection to the tab (for the edit menu).
final class SelectionRelay: NSObject, WKScriptMessageHandler {
    weak var owner: BrowserTab?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let text = message.body as? String ?? ""
        MainActor.assumeIsolated { owner?.lastSelection = text }
    }
}

/// The tab's web view: adds the search action to the selection edit menu.
final class FreedomWebView: WKWebView {
    var searchMenuTitle: (() -> String?)?
    var onSearchSelection: (() -> Void)?

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard let title = searchMenuTitle?() else { return }
        let action = UIAction(title: title, image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
            self?.onSearchSelection?()
        }
        builder.insertSibling(UIMenu(options: .displayInline, children: [action]), afterMenu: .standardEdit)
    }
}
