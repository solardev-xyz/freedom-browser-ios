import SwiftUI

/// The app's base layer is the tab overview; the browsing surface is a
/// full-screen presentation on top of it that zooms out of the active
/// tab's card (UIKit's zoom transition, Safari's model). "Open the
/// overview" is therefore a dismissal — the page shrinks into its card —
/// and picking a card presents the page growing out of it; the pinch
/// and drag-down to leave a page come with the transition.
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
                .navigationTransition(.zoom(sourceID: tabStore.activeRecordID ?? TabsRoot.noTab, in: tabZoom))
        }
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
