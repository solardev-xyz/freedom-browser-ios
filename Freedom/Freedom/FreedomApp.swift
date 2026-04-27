import SwiftUI
import SwiftData
import SwarmKit
import ENSNormalize

@main
struct FreedomApp: App {
    @State private var swarm: SwarmNode
    @State private var settings: SettingsStore
    @State private var historyStore: HistoryStore
    @State private var bookmarkStore: BookmarkStore
    @State private var faviconStore: FaviconStore
    @State private var tabStore: TabStore
    @State private var ensResolver: ENSResolver
    @State private var vault: Vault
    @State private var chainRegistry: ChainRegistry
    @State private var transactionService: TransactionService
    @State private var permissionStore: PermissionStore
    @State private var autoApproveStore: AutoApproveStore
    @State private var beeIdentity: BeeIdentityCoordinator
    @State private var beeReadiness: BeeReadiness
    private let modelContainer: ModelContainer

    init() {
        do {
            let container = try ModelContainer(
                for: TabRecord.self, HistoryEntry.self, Bookmark.self, Favicon.self,
                DappPermission.self, AutoApproveRule.self
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
            let vault = Vault()
            let registry = ChainRegistry(mainnetPool: pool)
            let permissions = PermissionStore(context: container.mainContext)
            let autoApprove = AutoApproveStore(context: container.mainContext)
            let txService = TransactionService(vault: vault, registry: registry)
            let wallet = WalletServices(
                vault: vault,
                chainRegistry: registry,
                permissionStore: permissions,
                autoApproveStore: autoApprove,
                transactionService: txService,
                ensResolver: resolver
            )
            self._vault = State(wrappedValue: vault)
            self._chainRegistry = State(wrappedValue: registry)
            self._permissionStore = State(wrappedValue: permissions)
            self._autoApproveStore = State(wrappedValue: autoApprove)
            self._transactionService = State(wrappedValue: txService)
            self._beeIdentity = State(wrappedValue: BeeIdentityCoordinator(settings: settings))
            let swarmInstance = SwarmNode()
            self._swarm = State(wrappedValue: swarmInstance)
            self._beeReadiness = State(wrappedValue: BeeReadiness(
                swarm: swarmInstance,
                settings: settings,
                walletRPC: registry.walletRPC
            ))
            self._tabStore = State(wrappedValue: TabStore(
                context: container.mainContext,
                historyStore: history,
                faviconStore: favicons,
                ensResolver: resolver,
                settings: settings,
                wallet: wallet
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
                .environment(vault)
                .environment(chainRegistry)
                .environment(transactionService)
                .environment(permissionStore)
                .environment(autoApproveStore)
                .environment(beeIdentity)
                .environment(beeReadiness)
                .modelContainer(modelContainer)
                .task { await startNodeIfNeeded() }
                .task { beeReadiness.start(intervalSeconds: 30) }
        }
    }

    private func startNodeIfNeeded() async {
        guard swarm.status == .idle else { return }
        do {
            // Legacy installs encrypted the keystore with the old hardcoded
            // password and can't be decrypted with the new random one.
            // Detected by Keychain absence; runs once per install.
            let isLegacyInstall = try BeePassword.readExisting() == nil
            if isLegacyInstall {
                try BeeStateDirs.wipeAll(at: SwarmNode.defaultDataDir())
                // Statestore is gone with the dir — bee would deploy a
                // fresh chequebook on the next light boot, orphaning the
                // user's previous on-chain one. Force back to ultralight
                // so they go through publish-setup intentionally.
                // (Reset BEFORE building config — the boot config reads
                // `settings.beeNodeMode` to decide swap-enable.)
                settings.beeNodeMode = .ultraLight
                settings.hasCompletedPublishSetup = false
            }
            let password = try BeePassword.loadOrCreate()
            let config = await BeeBootConfig.build(password: password, mode: settings.beeNodeMode)
            swarm.start(config)
        } catch {
            // SwarmNode stays `.idle`; a future scenePhase resume retries.
            print("startNodeIfNeeded failed: \(error)")
        }
    }
}
