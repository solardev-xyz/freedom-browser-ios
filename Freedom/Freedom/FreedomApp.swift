import SwiftUI
import SwiftData
import SwarmKit
import ENSNormalize

@main
struct FreedomApp: App {
    @State private var swarm = SwarmNode()
    @State private var settings: SettingsStore
    @State private var historyStore: HistoryStore
    @State private var bookmarkStore: BookmarkStore
    @State private var faviconStore: FaviconStore
    @State private var tabStore: TabStore
    @State private var ensResolver: ENSResolver
    private let modelContainer: ModelContainer

    init() {
        do {
            let container = try ModelContainer(
                for: TabRecord.self, HistoryEntry.self, Bookmark.self, Favicon.self
            )
            self.modelContainer = container
            let history = HistoryStore(context: container.mainContext)
            let bookmarks = BookmarkStore(context: container.mainContext)
            let favicons = FaviconStore(context: container.mainContext)
            let settings = SettingsStore()
            let pool = EthereumRPCPool(settings: settings)
            let resolver = ENSResolver(pool: pool, settings: settings)
            self._historyStore = State(wrappedValue: history)
            self._bookmarkStore = State(wrappedValue: bookmarks)
            self._faviconStore = State(wrappedValue: favicons)
            self._settings = State(wrappedValue: settings)
            self._ensResolver = State(wrappedValue: resolver)
            self._tabStore = State(wrappedValue: TabStore(
                context: container.mainContext,
                historyStore: history,
                faviconStore: favicons,
                ensResolver: resolver
            ))
        } catch {
            fatalError("Failed to create SwiftData ModelContainer: \(error)")
        }

        // ENSIP-15 tables (~MB of Unicode data) load lazily on first use.
        // Warm them off-main so the first ENS address-bar navigation
        // doesn't pay the deserialization cost on the main actor.
        Task.detached { _ = try? "a.eth".ensNormalized() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(swarm)
                .environment(settings)
                .environment(tabStore)
                .environment(historyStore)
                .environment(bookmarkStore)
                .environment(faviconStore)
                .environment(ensResolver)
                .modelContainer(modelContainer)
                .task { await startNodeIfNeeded() }
        }
    }

    private func startNodeIfNeeded() async {
        guard swarm.status == .idle else { return }
        let fresh = await BootnodeResolver.resolveMainnet()
        let bootnodes = fresh.isEmpty ? SwarmConfig.defaultBootnodes : fresh
        swarm.start(.init(
            dataDir: SwarmNode.defaultDataDir(),
            password: "freedom-default",  // TODO: Keychain in M4
            bootnodes: bootnodes.joined(separator: "|")
        ))
    }
}
