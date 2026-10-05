import SwiftUI
import WebKit
import OSLog
import SwiftData
import SwarmKit
import IPFSKit
import MyotisKit
import RadicleKit
import ENSNormalize

@main
struct FreedomApp: App {
    @State private var swarm: SwarmNode
    @State private var ipfs: IPFSNode
    @State private var myotis: MyotisNode
    @State private var radicle: RadicleNode
    @State private var radiclePermissionStore: RadiclePermissionStore
    @State private var radicleSeedTracker: RadicleSeedTracker
    @State private var settings: SettingsStore
    @State private var historyStore: HistoryStore
    @State private var bookmarkStore: BookmarkStore
    @State private var faviconStore: FaviconStore
    @State private var tabStore: TabStore
    @State private var ensResolver: ENSResolver
    @State private var vault: Vault
    @State private var userWallets: UserWalletStore
    @State private var chainRegistry: ChainRegistry
    @State private var chainStore: ChainStore
    @State private var transactionService: TransactionService
    @State private var permissionStore: PermissionStore
    @State private var autoApproveStore: AutoApproveStore
    @State private var openlvSession: OpenLVWalletSession
    @State private var beeIdentity: BeeIdentityCoordinator
    @State private var radicleIdentity = RadicleIdentityCoordinator()
    @State private var beeReadiness: BeeReadiness
    @State private var stampService: StampService
    @State private var storageFunding: StorageFundingController
    @State private var beeWalletInfo: BeeWalletInfo
    @State private var swarmPermissionStore: SwarmPermissionStore
    @State private var swarmFeedStore: SwarmFeedStore
    @State private var swarmPublishHistoryStore: SwarmPublishHistoryStore
    @State private var swarmManifestStore: SwarmManifestStore
    @State private var swarmUserPublisher: SwarmUserPublisher
    @State private var walletTransactionHistory: WalletTransactionHistoryStore
    @State private var walletBalances: WalletBalanceStore
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
                SwarmPublishHistoryRecord.self, RadiclePermission.self, WalletTransactionRecord.self,
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
            // The embedded P2P light client is the resolver's first tier;
            // availability is polled off the node, and the resolver skips
            // it whenever it can't serve.
            let myotisInstance = MyotisNode()
            // Host seed pins for cold starts (see docs/myotis-seed-pins.md):
            // one bundled list per network, a random subset pushed per boot.
            myotisInstance.seedEnodes = [
                .mainnet: MyotisSeedPins.load(Bundle.main.url(forResource: "seeds-mainnet", withExtension: "json")),
                .gnosis: MyotisSeedPins.load(Bundle.main.url(forResource: "seeds-gnosis", withExtension: "json")),
            ]
            // Stale-anchor recovery corroborates each quorum checkpoint
            // with a disposable Colibri verifier (desktop PR #353
            // parity). Without it a stale anchor blocks as unsupported.
            myotisInstance.checkpointCorroborator = ColibriCheckpointCorroborator()
            self._myotis = State(wrappedValue: myotisInstance)
            let myotisClient = MyotisENSClient(node: myotisInstance)
            let resolver = ENSResolver(
                pool: pool, settings: settings, colibri: colibri, myotis: myotisClient
            )
            // Sweep result caches on every availability flip so takeover
            // (quorum answers upgrade to P2P-verified) and failover don't
            // wait out cached TTLs — desktop parity.
            myotisInstance.onAvailabilityChange = { [weak resolver] _, _ in
                resolver?.sweepResultCaches()
            }
            // Every name the browser navigates goes through one resolver:
            // `.tez` to Tezos Domains, the rest to ENS (desktop's
            // content-name-resolver).
            let nameResolver = ContentNameResolver(ens: resolver, tezos: TezosDomainsResolver())
            let favicons = FaviconStore(context: container.mainContext, ensResolver: nameResolver)
            self._historyStore = State(wrappedValue: history)
            self._bookmarkStore = State(wrappedValue: bookmarks)
            self._faviconStore = State(wrappedValue: favicons)
            self._settings = State(wrappedValue: settings)
            self._ensResolver = State(wrappedValue: resolver)
            let vault = Vault()
            let userWallets = UserWalletStore(vault: vault)
            self._userWallets = State(wrappedValue: userWallets)
            let registry = ChainRegistry(chainStore: chainStore, mainnetPool: pool)
            // Verified chain-data sources for wallet + dApp reads
            // (desktop chain-data-router parity): Myotis answers first
            // where it can, Colibri second, the RPC pool last (walked
            // inside WalletRPC). Unsupported shapes fall through
            // per-source, so custom chains and pending-tag reads behave
            // exactly as before.
            registry.verifiedSources = [
                MyotisChainSource(node: myotisInstance),
                ColibriChainSource(settings: settings, chainStore: chainStore),
            ]
            let permissions = PermissionStore(context: container.mainContext)
            let autoApprove = AutoApproveStore(context: container.mainContext)
            let txService = TransactionService(vault: vault, registry: registry)
            let txHistory = WalletTransactionHistoryStore(context: container.mainContext)
            self._walletBalances = State(wrappedValue: WalletBalanceStore(registry: registry))
            txService.history = txHistory
            self._walletTransactionHistory = State(wrappedValue: txHistory)
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
            let beeIdentity = BeeIdentityCoordinator()
            self._beeIdentity = State(wrappedValue: beeIdentity)
            let swarmInstance = SwarmNode()
            // Ant's Gnosis reads and broadcasts go through the same
            // chain-data router as the wallet (desktop PR #419 parity)
            // instead of the pinned RPC in `BeeBootConfig`.
            swarmInstance.chainTransport = AntChainBridge(router: registry.walletRPC.router).transport
            // A first wallet scan the transport can't serve in a few windows
            // is read once from this explicitly unverified source and
            // re-confirmed in the background (ant #143); that one request
            // bypasses the router.
            swarmInstance.unverifiedLogsRPC = SwarmDefaults.pinnedGnosisRPC
            swarmInstance.setSwapEnabled(settings.swarmSwapEnabled)
            // A wallet scan no RPC quorum can serve is verified against
            // Blockscout's transfer index (desktop #484).
            let transferIndex = BlockscoutTransferIndex()
            transferIndex.isEnabled = { settings.gnosisTransferIndexEnabled }
            registry.walletRPC.router.transferIndex = transferIndex
            self._swarm = State(wrappedValue: swarmInstance)
            let ipfsInstance = IPFSNode()
            self._ipfs = State(wrappedValue: ipfsInstance)
            let readiness = BeeReadiness(swarm: swarmInstance)
            self._beeReadiness = State(wrappedValue: readiness)
            let stamps = StampService(swarm: swarmInstance, settings: settings)
            let walletInfo = BeeWalletInfo(swarm: swarmInstance, settings: settings)
            self._stampService = State(wrappedValue: stamps)
            self._beeWalletInfo = State(wrappedValue: walletInfo)
            // Storage plans are bought node-side (`ant_storage_*`); the
            // calls fall back to the pinned RPC when the chain transport
            // can't serve.
            swarmInstance.storageRPC = SwarmDefaults.pinnedGnosisRPC
            let storageFunding = StorageFundingController(ffi: .live(swarmInstance))
            // The running gateway lists a bought batch at once, but only
            // a repeated (idempotent) gateway start lets it adopt the
            // chequebook the buy deployed.
            // ant v0.5.52+: a C-API buy / deploy updates the running
            // gateway's chequebook slot itself; only the app's caches
            // need a re-read.
            let adoptChainState: @MainActor () async -> Void = {
                await readiness.refreshChequebookAddress()
                await walletInfo.refresh()
            }
            storageFunding.onActivated = { purchase in
                stamps.expectNewPlan()
                await stamps.refreshStamps()
                if case .buy = purchase { await adoptChainState() } else { await walletInfo.refresh() }
            }
            storageFunding.onSettlementSetUp = adoptChainState
            self._storageFunding = State(wrappedValue: storageFunding)
            let swarmPermissions = SwarmPermissionStore(context: container.mainContext)
            let feedStore = SwarmFeedStore(context: container.mainContext)
            let publishHistory = SwarmPublishHistoryStore(context: container.mainContext)
            self._swarmPermissionStore = State(wrappedValue: swarmPermissions)
            self._swarmFeedStore = State(wrappedValue: feedStore)
            self._swarmPublishHistoryStore = State(wrappedValue: publishHistory)
            let manifestFetcher = SwarmManifestFetcher(ensResolver: nameResolver)
            let manifestStore = SwarmManifestStore(
                fileURL: SwarmManifestStore.defaultFileURL(),
                permissionStore: swarmPermissions,
                feedStore: feedStore,
                discover: { await manifestFetcher.discover(committedURL: $0) }
            )
            self._swarmManifestStore = State(wrappedValue: manifestStore)
            // Composed once; closure reads the three observables live so a
            // sync tick / stamp purchase is reflected on the next
            // swarm_getCapabilities without rebuilding anything.
            let nodeFailureReason: @MainActor () -> String? = {
                if swarmInstance.status != .running {
                    return SwarmRouter.ErrorPayload.Reason.nodeStopped
                }
                if readiness.state != .ready {
                    return SwarmRouter.ErrorPayload.Reason.nodeNotReady
                }
                // Storage not read yet: not "no stamps".
                if !stamps.hasLoaded {
                    return SwarmRouter.ErrorPayload.Reason.nodeNotReady
                }
                // Still looking for storage the wallet owns (desktop #534).
                if WalletScanCopy.looking(swarmInstance.walletScan, hasUsableStorage: stamps.hasUsableStamps) != nil {
                    return SwarmRouter.ErrorPayload.Reason.nodeNotReady
                }
                if !stamps.hasUsableStamps {
                    return SwarmRouter.ErrorPayload.Reason.noUsableStamps
                }
                return nil
            }
            let swarmBee = BeeAPIClient()
            let swarmChunkService = SwarmChunkService.live(bee: swarmBee)
            let swarmServices = SwarmServices(
                permissionStore: swarmPermissions,
                feedStore: feedStore,
                manifestStore: manifestStore,
                publishHistoryStore: publishHistory,
                bee: swarmBee,
                publishService: SwarmPublishService.live(bee: swarmBee),
                feedService: SwarmFeedService.live(bee: swarmBee),
                chunkService: swarmChunkService,
                readBudget: SwarmReadBudget(),
                messagingService: SwarmMessagingService.live(
                    bee: swarmBee, chunkService: swarmChunkService
                ),
                subscriptionRegistry: SwarmSubscriptionRegistry(),
                vault: vault,
                tagOwnership: TagOwnership(),
                feedWriteLock: SwarmFeedWriteLock(),
                nodeFailureReason: nodeFailureReason,
                currentStamps: { stamps.stamps },
                getTag: { try await swarmBee.getTag(uid: $0) }
            )
            self._swarmUserPublisher = State(wrappedValue: SwarmUserPublisher(
                publishService: swarmServices.publishService,
                history: publishHistory,
                currentStamps: { stamps.stamps },
                getTag: { try await swarmBee.getTag(uid: $0) }
            ))
            // Embedded Radicle node (publish-capable: the no-spawn build
            // serves fetches in-process, so peers replicate the phone's
            // COB writes back). Provider gate mirrors desktop's
            // experimental setting via `nodeFailureReason`.
            let radicleInstance = RadicleNode()
            self._radicle = State(wrappedValue: radicleInstance)
            let radiclePermissions = RadiclePermissionStore(context: container.mainContext)
            self._radiclePermissionStore = State(wrappedValue: radiclePermissions)
            let radicleTracker = RadicleSeedTracker(node: radicleInstance)
            self._radicleSeedTracker = State(wrappedValue: radicleTracker)
            let radicleServices = RadicleServices(
                node: radicleInstance,
                permissionStore: radiclePermissions,
                seedTracker: radicleTracker,
                nodeFailureReason: {
                    if !settings.radicleNodeEnabled {
                        return RadicleBridge.ErrorPayload.Reason.integrationDisabled
                    }
                    switch radicleInstance.status {
                    case .running: return nil
                    case .starting: return RadicleBridge.ErrorPayload.Reason.nodeNotReady
                    default: return RadicleBridge.ErrorPayload.Reason.nodeStopped
                    }
                }
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
                ensResolver: nameResolver,
                settings: settings,
                wallet: wallet,
                swarm: swarmServices,
                radicle: radicleServices,
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
            TabsRoot()
                .environment(swarm)
                .environment(ipfs)
                .environment(myotis)
                .environment(radicle)
                .environment(radiclePermissionStore)
                .environment(radicleSeedTracker)
                .environment(settings)
                .environment(tabStore)
                .environment(historyStore)
                .environment(bookmarkStore)
                .environment(faviconStore)
                .environment(ensResolver)
                .environment(vault)
                .environment(userWallets)
                .environment(radicleIdentity)
                .environment(chainRegistry)
                .environment(chainStore)
                .environment(transactionService)
                .environment(walletTransactionHistory)
                .environment(walletBalances)
                .environment(permissionStore)
                .environment(autoApproveStore)
                .environment(beeIdentity)
                .environment(beeReadiness)
                .environment(stampService)
                .environment(storageFunding)
                .environment(beeWalletInfo)
                .environment(swarmPermissionStore)
                .environment(swarmFeedStore)
                .environment(swarmPublishHistoryStore)
                .environment(swarmManifestStore)
                .environment(swarmUserPublisher)
                .environment(adblock)
                .environment(adblockUpdate)
                .environment(openlvSession)
                // URLs from outside: the phone-signing pairing link
                // (`freedom://…#openlv://…`; universal links on the bridge
                // origin once an AASA file + the Associated Domains
                // entitlement land), and any page the browser can show —
                // a link tapped in another app, or http(s) once Freedom is
                // the default browser — which opens in a new tab.
                .onOpenURL { url in
                    switch IncomingLink.classify(url) {
                    case .openLV(let uri):
                        Task { try? await openlvSession.start(uri: uri) }
                    case .page(let browserURL):
                        tabStore.openFromOutside(browserURL)
                    case .payment(let url):
                        // ContentView turns it into the Send form once it is up.
                        tabStore.pendingEthereumURI = url
                        tabStore.externalOpenToken += 1
                    case .unsupported:
                        break
                    }
                }
                .modelContainer(modelContainer)
                .task { await startNodeIfNeeded() }
                .task { await repollPendingTransactions() }
                .task { startIpfsIfNeeded() }
                .task { startMyotisIfNeeded() }
                .task { await debugResolveIfRequested() }
                .task { await debugAccountIfRequested() }
                .task { await debugOpenURLIfRequested() }
                .task { await debugVaultIfRequested() }
                .task { await startRadicleIfNeeded() }
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
                .onChange(of: userWallets.activeIndex) { _, _ in
                    // One active wallet: every dapp grant follows it, and
                    // each connected tab's bridge emits accountsChanged.
                    if let address = try? vault.activeAddress() {
                        permissionStore.reassignAllGrants(to: address)
                    }
                }
                .onChange(of: vault.state) { _, state in
                    // A new or wiped vault starts over with Main Wallet.
                    if state == .empty { userWallets.reset() }
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await adblockUpdate.checkIfDue() }
                    // Phase D (minimal): iOS froze every thread while
                    // suspended, so the node's sessions are silently dead
                    // on return. Re-dial the preferred seeds immediately
                    // instead of waiting for the node's own timeouts to
                    // notice; connect is idempotent for live sessions.
                    if settings.radicleNodeEnabled, radicle.status == .running {
                        Task {
                            await radicle.connectSeeds()
                            await radicle.refreshStatus()
                        }
                    }
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

    /// Smoke-test hook (DEBUG builds only): `FREEDOM_DEBUG_RESOLVE=<name>`
    /// in the launch environment resolves that name once the mainnet
    /// light client reports ready (or after 90 s regardless) and logs the
    /// serving tier, so a simulator run can prove which tier answered
    /// without anyone typing into the URL bar
    /// (`log stream --predicate 'category == "DebugResolve"'`).
    private func debugResolveIfRequested() async {
        #if DEBUG
        guard let name = ProcessInfo.processInfo.environment["FREEDOM_DEBUG_RESOLVE"], !name.isEmpty else { return }
        let log = Logger(subsystem: "com.browser.Freedom", category: "DebugResolve")
        let deadline = Date().addingTimeInterval(90)
        while !myotis.isReady(chainId: MyotisNetwork.mainnet.chainId), Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        // Six attempts, 30 s apart, caches swept between them: shows
        // whether a tier failure is a warm-up transient or persistent.
        for attempt in 1...6 {
            ensResolver.sweepResultCaches()
            let chain = myotis.chainStatus[1]
            log.notice("[debug-resolve] attempt \(attempt) \(name, privacy: .public) myotisReady=\(myotis.isReady(chainId: 1), privacy: .public) snapPeers=\(chain?.snapPeers ?? -1) serving=\(chain?.snapServingPeers ?? -1) head=\(chain?.executionBlockNumber ?? 0) finalized=\(chain?.finalizedBlockNumber ?? 0)")
            do {
                let content = try await ensResolver.resolveContent(name)
                log.notice("[debug-resolve] attempt \(attempt) → \(content.uri.absoluteString, privacy: .public) method=\(content.trust.method.rawValue, privacy: .public) level=\(String(describing: content.trust.level), privacy: .public)")
            } catch {
                log.notice("[debug-resolve] attempt \(attempt) failed: \(String(describing: error), privacy: .public)")
            }
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
        #endif
    }

    /// Desktop `repollPending`: a transaction left pending by an earlier
    /// run gets one receipt lookup at launch.
    private func repollPendingTransactions() async {
        let rpc = chainRegistry.walletRPC
        let store = chainStore
        await walletTransactionHistory.repollPending { hash, chainID in
            guard let chain = store.chain(id: chainID) else { return nil }
            return try await rpc.getTransactionReceipt(hash: hash, on: chain)
        }
    }

    /// Smoke-test hook (DEBUG builds only): `FREEDOM_DEBUG_ACCOUNT=<chainId>:<address>`
    /// issues a verified account read (balance + nonce, the wallet's
    /// Gnosis read) through the light client once that chain reports
    /// ready (or after 90 s regardless), six times 30 s apart, logging
    /// served/failed with the time taken — the Gnosis twin of the resolve
    /// hook, used to probe seed peers
    /// (`log stream --predicate 'category == "DebugAccount"'`).
    /// Smoke-test hook (DEBUG, simulator only): `FREEDOM_DEBUG_VAULT=import:<phrase>`
    /// creates the vault from a phrase at launch when none exists, then
    /// reports for a minute whether the Radicle node's DID has moved to
    /// the one that phrase derives (`log stream --predicate 'category == "DebugVault"'`).
    /// `FREEDOM_DEBUG_VAULT=wipe` wipes an existing vault. Never on a device.
    private func debugVaultIfRequested() async {
        #if DEBUG && targetEnvironment(simulator)
        guard let raw = ProcessInfo.processInfo.environment["FREEDOM_DEBUG_VAULT"], !raw.isEmpty else { return }
        let log = Logger(subsystem: "com.browser.Freedom", category: "DebugVault")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if raw == "wipe" {
            do { try await vault.wipe(); log.notice("[debug-vault] wiped") } catch { log.notice("[debug-vault] wipe failed: \(error.localizedDescription, privacy: .public)") }
            return
        }
        guard raw.hasPrefix("import:") else { return }
        let phrase = String(raw.dropFirst("import:".count))
        guard vault.state == .empty else {
            // An existing (locked) vault: report what the node booted as.
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            log.notice("[debug-vault] vault exists (\(String(describing: vault.state), privacy: .public)); radicle=\(String(describing: radicle.status), privacy: .public) did=\(radicle.identity?.did ?? "-", privacy: .public)")
            return
        }
        do {
            let mnemonic = try Mnemonic(phrase: phrase)
            try await vault.create(mnemonic: mnemonic)
            let expected = try RadicleIdentityKey.derive(fromSeed: mnemonic.seed()).did
            log.notice("[debug-vault] imported; expecting radicle DID \(expected, privacy: .public)")
            for tick in 1...30 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let did = radicle.identity?.did ?? "-"
                log.notice("[debug-vault] t=\(tick * 2)s radicle=\(String(describing: radicle.status), privacy: .public) did=\(did, privacy: .public) match=\(did == expected, privacy: .public)")
                if did == expected { break }
            }
        } catch {
            log.notice("[debug-vault] import failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    private func debugAccountIfRequested() async {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["FREEDOM_DEBUG_ACCOUNT"],
              let colon = raw.firstIndex(of: ":"), let chainId = UInt64(raw[..<colon])
        else { return }
        let address = String(raw[raw.index(after: colon)...])
        guard address.hasPrefix("0x"), address.count == 42 else { return }
        let log = Logger(subsystem: "com.browser.Freedom", category: "DebugAccount")
        let deadline = Date().addingTimeInterval(90)
        while !myotis.isReady(chainId: chainId), Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        for attempt in 1...6 {
            let chain = myotis.chainStatus[chainId]
            log.notice("[debug-account] attempt \(attempt) chain=\(chainId) ready=\(myotis.isReady(chainId: chainId), privacy: .public) snapPeers=\(chain?.snapPeers ?? -1) serving=\(chain?.snapServingPeers ?? -1) head=\(chain?.executionBlockNumber ?? 0)")
            let started = Date()
            let outcome = await myotis.requestAccount(chainId: chainId, address: address)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            switch outcome {
            case .ok(let balanceWei, let nonce):
                log.notice("[debug-account] attempt \(attempt) served in \(ms)ms balance=\(balanceWei, privacy: .public) nonce=\(nonce)")
            case .unavailable(let reason):
                log.notice("[debug-account] attempt \(attempt) failed after \(ms)ms: \(reason, privacy: .public)")
            }
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
        #endif
    }

    /// Smoke-test hook (DEBUG builds only): `FREEDOM_DEBUG_OPEN_URL=<url>`
    /// navigates the active tab to the URL at launch and logs what the
    /// tab does with it for a minute — fetch, gate, trust, page title —
    /// so a simulator run can prove an onchain app (or any URL) loads
    /// end to end without anyone typing. If the navigation lands on an
    /// unverified-onchain gate, the hook continues past it once, which
    /// is exactly the tap a smoke tester would make
    /// (`log stream --predicate 'category == "DebugOpen"'`).
    private func debugOpenURLIfRequested() async {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["FREEDOM_DEBUG_OPEN_URL"],
              let target = BrowserURL.parse(raw) else { return }
        let log = Logger(subsystem: "com.browser.Freedom", category: "DebugOpen")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        log.notice("[debug-open] navigating to \(target.url.absoluteString, privacy: .public)")
        tabStore.navigateActive(to: target)
        var continued = false
        for tick in 1...30 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let tab = tabStore.activeTab else { continue }
            let gate: String
            switch tab.pendingGate {
            case .unverifiedOnchain(let document, _):
                gate = "unverifiedOnchain source=\(document.provenance.source) hash=\(document.provenance.htmlHash)"
            case .some(let other): gate = String(describing: other).prefix(60).description
            case nil: gate = "none"
            }
            let title = (try? await tab.webView.evaluateJavaScript("document.title") as? String) ?? ""
            let length = (try? await tab.webView.evaluateJavaScript("document.documentElement.outerHTML.length") as? Int) ?? 0
            log.notice("[debug-open] t=\(tick * 2)s status=\(String(describing: tab.ensStatus).prefix(80), privacy: .public) gate=\(gate, privacy: .public) url=\(tab.displayURL?.absoluteString ?? "-", privacy: .public) trust=\(tab.currentTrust.map { "\($0.method.rawValue)/\($0.level)" } ?? "-", privacy: .public) onchainHash=\(tab.currentOnchain?.htmlHash ?? "-", privacy: .public) title=\(title, privacy: .public) domLength=\(length)")
            if case .unverifiedOnchain = tab.pendingGate, !continued {
                continued = true
                log.notice("[debug-open] continuing past the unverified-onchain gate once")
                tab.continuePastGate()
            }
        }
        #endif
    }

    /// Brings the Myotis light client up alongside the other embedded
    /// nodes (mainnet + Gnosis). Fire-and-forget: engine creation and
    /// sync happen on a detached task inside the wrapper, and resolution
    /// falls back to Colibri/quorum until a chain reports ready.
    private func startMyotisIfNeeded() {
        // Never boot live P2P engines inside the unit-test host: tests
        // inject closure-seamed fakes, and two devp2p/libp2p engines
        // doing real sync in the background make the runner
        // nondeterministic (observed: heap-corruption aborts taking
        // unrelated tests down). Swarm/IPFS effectively skip in tests
        // via their config/keychain paths; Myotis needs the explicit
        // guard because it has no such accidental gate.
        guard NSClassFromString("XCTestCase") == nil else { return }
        let networks = settings.myotisEnabledNetworks
        guard !networks.isEmpty else { return }
        guard myotis.status == .idle else { return }
        myotis.start(networks: networks)
    }

    /// Brings the embedded Radicle node up alongside the other nodes.
    /// Same XCTest guard as Myotis: never boot a live P2P node inside
    /// the unit-test host. Seeds are dialed once after start; radicle's
    /// own connection maintenance takes over from there.
    private func startRadicleIfNeeded() async {
        guard NSClassFromString("XCTestCase") == nil else { return }
        guard settings.radicleNodeEnabled else { return }
        guard radicle.status == .idle else { return }
        await RadicleRuntime.start(radicle)
        guard radicle.status == .running else { return }
        await radicle.connectSeeds()
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
                // ant rediscovers owned batches and a chequebook the node
                // wallet ever funded at the next gateway start; nothing
                // is deployed until the user buys storage again.
            }
            let password = try BeePassword.loadOrCreate()
            let config = await BeeBootConfig.build(password: password)
            swarm.start(config)
        } catch {
            // SwarmNode stays `.idle`; a future scenePhase resume retries.
            print("startNodeIfNeeded failed: \(error)")
        }
    }
}
