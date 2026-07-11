import SwiftUI
import SwiftData
import SwarmKit
import IPFSKit
import ENSNormalize

@main
struct FreedomApp: App {
    @State private var swarm: SwarmNode
    @State private var ipfs: IPFSNode
    @State private var settings: SettingsStore
    @State private var historyStore: HistoryStore
    @State private var bookmarkStore: BookmarkStore
    @State private var faviconStore: FaviconStore
    @State private var tabStore: TabStore
    @State private var ensResolver: ENSResolver
    @State private var vault: Vault
    @State private var chainRegistry: ChainRegistry
    @State private var chainStore: ChainStore
    @State private var transactionService: TransactionService
    @State private var permissionStore: PermissionStore
    @State private var autoApproveStore: AutoApproveStore
    @State private var openlvSession: OpenLVWalletSession
    @State private var beeIdentity: BeeIdentityCoordinator
    @State private var beeReadiness: BeeReadiness
    @State private var stampService: StampService
    @State private var beeWalletInfo: BeeWalletInfo
    @State private var swarmPermissionStore: SwarmPermissionStore
    @State private var swarmFeedStore: SwarmFeedStore
    @State private var swarmPublishHistoryStore: SwarmPublishHistoryStore
    @State private var adblock: AdblockService
    @State private var adblockUpdate: AdblockUpdateService
    @Environment(\.scenePhase) private var scenePhase
    private let modelContainer: ModelContainer

    init() {
        do {
            let container = try ModelContainer(
                for: TabRecord.self, HistoryEntry.self, Bookmark.self, Favicon.self,
                DappPermission.self, AutoApproveRule.self,
                SwarmPermission.self, SwarmFeedRecord.self, SwarmFeedIdentity.self,
                SwarmPublishHistoryRecord.self,
                ChainRecord.self
            )
            self.modelContainer = container
            let history = HistoryStore(context: container.mainContext)
            let bookmarks = BookmarkStore(context: container.mainContext)
            let settings = SettingsStore()
            // Seed the chain backing (mainnet + Gnosis) before any RPC
            // pool / resolver constructs against it. WP3 swaps the pool's
            // URL source to the store; for now the store just runs the
            // one-time migration of `ensPublicRpcProviders`.
            let chainStore = ChainStore(context: container.mainContext, settings: settings)
            // Colibri's verifier persists sync-committee state across
            // launches. Register the disk-backed storage adapter once at
            // startup, before any code path can construct a Colibri client.
            ColibriDiskStorage.register()
            // Mainnet pool sources URLs from the chain store; the same
            // instance flows into `ENSResolver` and `ChainRegistry` so
            // ENS and wallet share mainnet quarantine state.
            let pool = EthereumRPCPool(
                chainID: Chain.mainnetID,
                urlSource: { chainStore.rpcURLs(forChainID: Chain.mainnetID) }
            )
            let colibri = ColibriENSClient(settings: settings, chainStore: chainStore)
            let resolver = ENSResolver(pool: pool, settings: settings, colibri: colibri)
            let favicons = FaviconStore(context: container.mainContext, ensResolver: resolver)
            self._historyStore = State(wrappedValue: history)
            self._bookmarkStore = State(wrappedValue: bookmarks)
            self._faviconStore = State(wrappedValue: favicons)
            self._settings = State(wrappedValue: settings)
            self._ensResolver = State(wrappedValue: resolver)
            let vault = Vault()
            let registry = ChainRegistry(chainStore: chainStore, mainnetPool: pool)
            let permissions = PermissionStore(context: container.mainContext)
            let autoApprove = AutoApproveStore(context: container.mainContext)
            let txService = TransactionService(vault: vault, registry: registry)
            let wallet = WalletServices(
                vault: vault,
                chainRegistry: registry,
                chainStore: chainStore,
                permissionStore: permissions,
                autoApproveStore: autoApprove,
                transactionService: txService,
                ensResolver: resolver
            )
            let openlv = OpenLVWalletSession(
                services: wallet,
                activeChain: { WalletDefaults.activeChain(in: chainStore) }
            )
            self._openlvSession = State(wrappedValue: openlv)
            self._vault = State(wrappedValue: vault)
            self._chainRegistry = State(wrappedValue: registry)
            self._chainStore = State(wrappedValue: chainStore)
            self._permissionStore = State(wrappedValue: permissions)
            self._autoApproveStore = State(wrappedValue: autoApprove)
            self._transactionService = State(wrappedValue: txService)
            self._beeIdentity = State(wrappedValue: BeeIdentityCoordinator(settings: settings))
            let swarmInstance = SwarmNode()
            self._swarm = State(wrappedValue: swarmInstance)
            let ipfsInstance = IPFSNode()
            self._ipfs = State(wrappedValue: ipfsInstance)
            let readiness = BeeReadiness(swarm: swarmInstance, settings: settings)
            self._beeReadiness = State(wrappedValue: readiness)
            let stamps = StampService(swarm: swarmInstance, settings: settings)
            let walletInfo = BeeWalletInfo(swarm: swarmInstance, settings: settings)
            // Stamp service triggers a chequebook auto-deposit after
            // every successful purchase; the attach lets it nudge
            // BeeWalletInfo to refresh balances once the deposit lands
            // instead of waiting for the next 30s poll tick.
            stamps.attach(walletInfo: walletInfo)
            self._stampService = State(wrappedValue: stamps)
            self._beeWalletInfo = State(wrappedValue: walletInfo)
            let swarmPermissions = SwarmPermissionStore(context: container.mainContext)
            let feedStore = SwarmFeedStore(context: container.mainContext)
            let publishHistory = SwarmPublishHistoryStore(context: container.mainContext)
            self._swarmPermissionStore = State(wrappedValue: swarmPermissions)
            self._swarmFeedStore = State(wrappedValue: feedStore)
            self._swarmPublishHistoryStore = State(wrappedValue: publishHistory)
            // Composed once; closure reads the four observables live so a
            // mode flip / sync tick / stamp purchase is reflected on the
            // next swarm_getCapabilities without rebuilding anything.
            let nodeFailureReason: @MainActor () -> String? = {
                if swarmInstance.status != .running {
                    return SwarmRouter.ErrorPayload.Reason.nodeStopped
                }
                if settings.beeNodeMode == .ultraLight {
                    return SwarmRouter.ErrorPayload.Reason.ultraLightMode
                }
                if readiness.state != .ready {
                    return SwarmRouter.ErrorPayload.Reason.nodeNotReady
                }
                if !stamps.hasUsableStamps {
                    return SwarmRouter.ErrorPayload.Reason.noUsableStamps
                }
                return nil
            }
            let swarmBee = BeeAPIClient()
            let swarmServices = SwarmServices(
                permissionStore: swarmPermissions,
                feedStore: feedStore,
                publishHistoryStore: publishHistory,
                bee: swarmBee,
                publishService: SwarmPublishService.live(bee: swarmBee),
                feedService: SwarmFeedService.live(bee: swarmBee),
                chunkService: SwarmChunkService.live(bee: swarmBee),
                readBudget: SwarmReadBudget(),
                vault: vault,
                tagOwnership: TagOwnership(),
                feedWriteLock: SwarmFeedWriteLock(),
                nodeFailureReason: nodeFailureReason,
                currentStamps: { stamps.stamps },
                getTag: { try await swarmBee.getTag(uid: $0) }
            )
            let adblockService = AdblockService(settings: settings)
            self._adblock = State(wrappedValue: adblockService)
            self._adblockUpdate = State(wrappedValue: AdblockUpdateService(
                settings: settings,
                io: .live(adblock: adblockService, bee: swarmBee)
            ))
            self._tabStore = State(wrappedValue: TabStore(
                context: container.mainContext,
                historyStore: history,
                faviconStore: favicons,
                ensResolver: resolver,
                settings: settings,
                wallet: wallet,
                swarm: swarmServices,
                adblock: adblockService,
                ipfs: ipfsInstance
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
                .environment(ipfs)
                .environment(settings)
                .environment(tabStore)
                .environment(historyStore)
                .environment(bookmarkStore)
                .environment(faviconStore)
                .environment(ensResolver)
                .environment(vault)
                .environment(chainRegistry)
                .environment(chainStore)
                .environment(transactionService)
                .environment(permissionStore)
                .environment(autoApproveStore)
                .environment(beeIdentity)
                .environment(beeReadiness)
                .environment(stampService)
                .environment(beeWalletInfo)
                .environment(swarmPermissionStore)
                .environment(swarmFeedStore)
                .environment(swarmPublishHistoryStore)
                .environment(adblock)
                .environment(openlvSession)
                // openlv links arrive via the custom `freedom://` scheme
                // (and, once the production bridge deploy serves an AASA
                // file + the Associated Domains entitlement lands, via
                // universal links on the bridge origin). Anything else
                // is not ours to handle here.
                .onOpenURL { url in
                    guard let uri = OpenLVWalletSession.extractOpenLVURI(from: url.absoluteString) else { return }
                    Task { try? await openlvSession.start(uri: uri) }
                }
                .modelContainer(modelContainer)
                .task { await startNodeIfNeeded() }
                .task { startIpfsIfNeeded() }
                .task { beeReadiness.start() }
                .task { stampService.start() }
                .task { beeWalletInfo.start() }
                // Compile bundled rule lists once on launch. Cached compiles
                // (same identifier) finish in ms; cold compiles ~1s for the
                // largest shards. Off the main path so first frame isn't blocked.
                .task { await adblock.compileBundledIfNeeded() }
                // Check the Swarm feed for fresher lists. Delayed so the
                // embedded node has time to come up; a feed-unavailable
                // outcome doesn't burn the 6h window, so a slow node start
                // just means the foreground hook below retries. No-op until
                // the trust anchor is compiled in.
                .task {
                    try? await Task.sleep(for: .seconds(30))
                    await adblockUpdate.checkIfDue()
                }
                // Foreground retry: the 6h gate makes this a cheap no-op most
                // of the time, and it picks up checks the launch task missed
                // (node not up yet, app long-suspended).
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await adblockUpdate.checkIfDue() }
                }
                // Process-killed-mid-publish rows have no in-memory state
                // to resume from; flip them to `failed` once on cold start.
                // Off the init critical path — fetch is unbounded and
                // shouldn't block first frame on a power user's history.
                .task { swarmPublishHistoryStore.sweepOrphans() }
        }
    }

    /// Brings the Rust IPFS reader up alongside bee. Runs in parallel
    /// with `startNodeIfNeeded` so a slow ENS / RPC / chequebook
    /// bring-up on the bee side doesn't block IPFS from coming online
    /// (and vice versa). `IPFSNode.start` is fire-and-forget — actual
    /// gateway bringup happens on a detached task inside the wrapper.
    private func startIpfsIfNeeded() {
        guard settings.ipfsNodeEnabled else { return }
        guard ipfs.status == .idle else { return }
        let config = settings.ipfsConfig(dataDir: IPFSNode.defaultDataDir())
        ipfs.start(config)
    }

    private func startNodeIfNeeded() async {
        guard settings.swarmNodeEnabled else { return }
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
