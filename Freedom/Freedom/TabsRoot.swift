import SwiftUI
import UIKit

/// The app's base layer is the tab overview; the browsing surface is a
/// full-screen presentation on top of it that zooms out of the active
/// tab's card (UIKit's zoom transition, Safari's model). "Open the
/// overview" is therefore a dismissal — the page shrinks into its card —
/// and picking a card presents the page growing out of it; the pinch
/// and drag-down to leave a page come with the transition. The swipe
/// from the left edge that also comes with it is turned off: the edges
/// belong to Back and Forward, as in Safari (`ZoomEdgeSwipeYield`).
struct TabsRoot: View {
    @Environment(TabStore.self) private var tabStore
    /// The page is up. Starts true so launch shows the page as before.
    @State private var isBrowsing: Bool
    /// Bumped every time the overview is revealed; the switcher lands on
    /// the active card and its group on each change.
    @State private var revealToken = 0
    @Namespace private var tabZoom

    init() {
        var browsing = true
        #if DEBUG
        // `FREEDOM_DEBUG_SHOW=tabs`: start on the overview (screenshots).
        if ProcessInfo.processInfo.environment["FREEDOM_DEBUG_SHOW"] == "tabs" { browsing = false }
        #endif
        _isBrowsing = State(initialValue: browsing)
    }

    var body: some View {
        TabSwitcher(namespace: tabZoom, revealToken: revealToken) {
            // A card was picked, + tapped, or Done: bring the page up.
            isBrowsing = true
        }
        .fullScreenCover(isPresented: $isBrowsing) {
            ContentView(onShowTabs: showTabs)
                .background(ZoomEdgeSwipeYield())
                .navigationTransition(.zoom(sourceID: tabStore.activeRecordID ?? TabsRoot.noTab, in: tabZoom))
        }
        // A link from another app opened a tab: show it, overview or not.
        .onChange(of: tabStore.externalOpenToken) { _, _ in isBrowsing = true }
    }

    /// A source id no card carries: with no active tab the presentation
    /// falls back to the system's default transition.
    private static let noTab = UUID()

    /// The page's pixels animate down into its card, so the card must
    /// already show the current page: snapshot first, then dismiss.
    private func showTabs() {
        Task { @MainActor in
            await tabStore.captureActive()
            revealToken += 1
            isBrowsing = false
        }
    }
}

/// Turns off the zoom transition's swipe-from-the-left-edge dismissal for
/// the presentation this sits in, so the edge swipe reaches the page's
/// Back gesture (WKWebView's back/forward swipes, BrowserTab) instead of
/// shrinking the page into the overview. The zoom's pinch and swipe-down
/// stay. UIKit installs these on the presented controller's view, the
/// edge one as a `UIScreenEdgePanGestureRecognizer`; SwiftUI's
/// `.zoom` transition has no option to leave it out.
private struct ZoomEdgeSwipeYield: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { Anchor() }
    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class Anchor: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            yieldEdge()
            // UIKit has installed them by now; check once more after this
            // turn in case a later iOS installs them as the presentation settles.
            DispatchQueue.main.async { [weak self] in self?.yieldEdge() }
        }

        private func yieldEdge() {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let controller = next as? UIViewController, controller.presentingViewController != nil {
                    for recognizer in controller.view.gestureRecognizers ?? [] where recognizer is UIScreenEdgePanGestureRecognizer {
                        recognizer.isEnabled = false
                    }
                    return
                }
                responder = next
            }
        }
    }
}
