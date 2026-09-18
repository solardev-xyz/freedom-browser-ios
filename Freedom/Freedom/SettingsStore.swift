import Foundation
import IPFSKit

enum BlockAnchor: String, CaseIterable, Hashable {
    case latest
    case latestMinus32 = "latest-32"
    case finalized
}

@MainActor
@Observable
final class SettingsStore {
    /// Mainnet public RPC seed. Every entry answered `eth_blockNumber`
    /// and an `eth_call` without an API key when the list was refreshed
    /// from chainlist.org (2026-09-18); keyless endpoints with tracking
    /// or paid-only `eth_call` were left out. Bump `legacyPublicRpcProviders`
    /// when changing this so `ChainStore` can refresh existing installs.
    static let defaultPublicRpcProviders: [String] = [
        "https://ethereum-rpc.publicnode.com",
        "https://eth.drpc.org",
        "https://eth-mainnet.public.blastapi.io",
        "https://ethereum-public.nodies.app",
        "https://ethereum.public.blockpi.network/v1/rpc/public",
        "https://0xrpc.io/eth",
        "https://ethereum-json-rpc.stakely.io",
        "https://rpc.fullsend.to",
        "https://eth.api.pocket.network",
    ]

    /// Every mainnet seed that ever shipped, so a record seeded by an
    /// older build can tell the user's own additions from stale defaults.
    static let legacyPublicRpcProviders: Set<String> = [
        "https://ethereum.publicnode.com",
        "https://1rpc.io/eth",
        "https://eth.drpc.org",
        "https://eth-mainnet.public.blastapi.io",
        "https://eth.merkle.io",
        "https://cloudflare-eth.com",
        "https://rpc.ankr.com/eth",
        "https://rpc.flashbots.net",
        "https://eth.llamarpc.com",
    ]

    var ensRpcUrl: String {
        didSet { defaults.set(ensRpcUrl, forKey: Keys.ensRpcUrl) }
    }
    /// Primary ENS resolution path. Default `.quorum` for now — Step 4 of
    /// the Colibri rollout flips it to `.colibri` for fresh installs after
    /// the trust popover + auto-migration land. While the default is
    /// `.quorum`, switching to `.colibri` in settings activates the
    /// cryptographically-verified path with `ensFallbackToQuorum` as a
    /// safety net.
    /// Legacy single-method picker, kept as a shim over the resolution
    /// order: reading it reports the first enabled non-Myotis method,
    /// setting it rewrites the order the way the one-time migration
    /// does (desktop `legacyOrder`). Tests and old call sites use it.
    var ensResolutionMethod: ENSResolutionMethod {
        get {
            ensEnabledResolutionMethods.first { $0 != .myotis } ?? .colibri
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.ensResolutionMethod)
            applyLegacyOrder(primary: newValue)
        }
    }
    /// Legacy "fall back to quorum" toggle for the Colibri method: now
    /// simply whether RPC quorum is enabled after Colibri.
    var ensFallbackToQuorum: Bool {
        get { ensResolutionEnabled.contains(.quorum) }
        set {
            defaults.set(newValue, forKey: Keys.ensFallbackToQuorum)
            setResolutionMethod(.quorum, enabled: newValue)
        }
    }
    /// Legacy quorum switch. Turning it off enables Direct RPC in its
    /// place, which is what the old single-source degrade did.
    var enableEnsQuorum: Bool {
        get { ensResolutionEnabled.contains(.quorum) }
        set {
            defaults.set(newValue, forKey: Keys.enableEnsQuorum)
            setResolutionMethod(.quorum, enabled: newValue)
            if !newValue { setResolutionMethod(.userConfigured, enabled: true) }
        }
    }

    /// Name-resolution methods in priority order, every method listed
    /// once (desktop "Resolution order"). `ensResolutionEnabled` says
    /// which of them run; `ensEnabledResolutionMethods` is the walk.
    var ensResolutionOrder: [ENSResolutionMethod] {
        // No self-assignment here: under @Observable the observer would
        // re-enter itself. Writers pass a permutation of
        // `resolutionMethods` (see `setResolutionOrder`).
        didSet { defaults.set(ensResolutionOrder.map(\.rawValue), forKey: Keys.ensResolutionOrder) }
    }
    var ensResolutionEnabled: Set<ENSResolutionMethod> {
        didSet {
            defaults.set(ensResolutionEnabled.map(\.rawValue).sorted(), forKey: Keys.ensResolutionEnabled)
        }
    }
    /// Keep an unverified (Direct RPC) answer as a fallback while later
    /// enabled methods try to produce a verified one.
    var ensPreferVerified: Bool {
        didSet { defaults.set(ensPreferVerified, forKey: Keys.ensPreferVerified) }
    }

    var ensEnabledResolutionMethods: [ENSResolutionMethod] {
        ensResolutionOrder.filter { ensResolutionEnabled.contains($0) }
    }

    /// The methods the order lists, in default priority. `.direct` is
    /// the router's trust label, never an ENS method; `.userConfigured`
    /// is the "Direct RPC" row (the user's own endpoint if set, else the
    /// pool's first answer).
    static let resolutionMethods: [ENSResolutionMethod] = [.myotis, .colibri, .quorum, .userConfigured]
    static let defaultResolutionEnabled: Set<ENSResolutionMethod> = [.myotis, .colibri, .quorum]

    func setResolutionMethod(_ method: ENSResolutionMethod, enabled: Bool) {
        if enabled { ensResolutionEnabled.insert(method) } else { ensResolutionEnabled.remove(method) }
    }

    /// Store an order; every method ends up listed exactly once.
    func setResolutionOrder(_ order: [ENSResolutionMethod]) {
        ensResolutionOrder = Self.normalizedOrder(order)
    }

    /// Desktop `legacyOrder`: Myotis first, then the primary and what it
    /// used to fall back to.
    private func applyLegacyOrder(primary: ENSResolutionMethod) {
        let tail: [ENSResolutionMethod]
        var enabled: Set<ENSResolutionMethod> = [.myotis]
        switch primary {
        case .userConfigured, .direct:
            // Custom-RPC users chose their node for privacy: nothing
            // public runs after it (the fail-closed policy predates the
            // order and survives it).
            tail = [.userConfigured, .quorum]
            enabled.insert(.userConfigured)
        case .quorum:
            tail = [.quorum]
            enabled.insert(.quorum)
        case .colibri, .myotis:
            tail = [.colibri, .quorum]
            enabled.formUnion([.colibri, .quorum])
        }
        ensResolutionOrder = Self.normalizedOrder([.myotis] + tail)
        ensResolutionEnabled = enabled
    }

    /// Every method exactly once, unknown entries dropped, missing ones
    /// appended in default priority.
    static func normalizedOrder(_ order: [ENSResolutionMethod]) -> [ENSResolutionMethod] {
        var seen: Set<ENSResolutionMethod> = []
        var out: [ENSResolutionMethod] = []
        for method in order + resolutionMethods where resolutionMethods.contains(method) && !seen.contains(method) {
            seen.insert(method)
            out.append(method)
        }
        return out
    }

    var ensColibriProverUrl: String {
        didSet { defaults.set(ensColibriProverUrl, forKey: Keys.ensColibriProverUrl) }
    }
    /// ZK sync-committee proof on the Colibri bootstrap. Avoids the
    /// checkpointz round-trip — partner-recommended on.
    var ensColibriZkProof: Bool {
        didSet { defaults.set(ensColibriZkProof, forKey: Keys.ensColibriZkProof) }
    }
    var ensQuorumK: Int {
        didSet { defaults.set(ensQuorumK, forKey: Keys.ensQuorumK) }
    }
    var ensQuorumM: Int {
        didSet { defaults.set(ensQuorumM, forKey: Keys.ensQuorumM) }
    }
    var ensQuorumTimeoutMs: Int {
        didSet { defaults.set(ensQuorumTimeoutMs, forKey: Keys.ensQuorumTimeoutMs) }
    }
    var ensBlockAnchor: BlockAnchor {
        didSet { defaults.set(ensBlockAnchor.rawValue, forKey: Keys.ensBlockAnchor) }
    }
    var ensBlockAnchorTtlMs: Int {
        didSet { defaults.set(ensBlockAnchorTtlMs, forKey: Keys.ensBlockAnchorTtlMs) }
    }
    var ensPublicRpcProviders: [String] {
        didSet { defaults.set(ensPublicRpcProviders, forKey: Keys.ensPublicRpcProviders) }
    }
    /// One-shot marker flipped the first time `ChainStore` seeds the
    /// SwiftData backing. Gates the migration of `ensPublicRpcProviders`
    /// into the mainnet `ChainRecord` so a wipe-and-reseed can't re-
    /// import a stale UserDefaults list over a user's later edits.
    var chainStoreMigrated: Bool {
        didSet { defaults.set(chainStoreMigrated, forKey: Keys.chainStoreMigrated) }
    }
    var blockUnverifiedEns: Bool {
        didSet { defaults.set(blockUnverifiedEns, forKey: Keys.blockUnverifiedEns) }
    }
    var enableCcipRead: Bool {
        didSet { defaults.set(enableCcipRead, forKey: Keys.enableCcipRead) }
    }
    var beeNodeMode: BeeNodeMode {
        didSet { defaults.set(beeNodeMode.rawValue, forKey: Keys.beeNodeMode) }
    }
    /// IPFS reader content-routing mode. `.autoclient` is the default
    /// — delegated routing with a light-DHT fallback. Cheapest config
    /// on mobile.
    var ipfsRoutingMode: IPFSRoutingMode {
        didSet { defaults.set(ipfsRoutingMode.rawValue, forKey: Keys.ipfsRoutingMode) }
    }
    /// Whether the reader runs on tighter request/provider budgets
    /// (lower concurrency and DHT fan-out). Right setting for mobile
    /// by default.
    var ipfsLowPower: Bool {
        didSet { defaults.set(ipfsLowPower, forKey: Keys.ipfsLowPower) }
    }
    /// True once the user has successfully reached light-mode `.ready` at
    /// least once. Drives the inline mode toggle in `NodeHomeView`: a true
    /// flag means bee's statestore still has the `swap_chequebook` entry
    /// (we never wipe across mode toggles), so flipping back to light is
    /// safe — bee picks up the existing chequebook, no redeploy.
    /// Cleared whenever we wipe statestore (vault wipe, legacy migration).
    var hasCompletedPublishSetup: Bool {
        didSet { defaults.set(hasCompletedPublishSetup, forKey: Keys.hasCompletedPublishSetup) }
    }
    /// Block ads via EasyList. Default on.
    var adblockAdsEnabled: Bool {
        didSet { defaults.set(adblockAdsEnabled, forKey: Keys.adblockAdsEnabled) }
    }
    /// Block trackers via EasyPrivacy. Default on.
    var adblockPrivacyEnabled: Bool {
        didSet { defaults.set(adblockPrivacyEnabled, forKey: Keys.adblockPrivacyEnabled) }
    }
    /// Block cookie banners via Fanboy's Cookiemonster. Default off — hides
    /// banners users may want to see for genuine consent decisions.
    var adblockCookiesEnabled: Bool {
        didSet { defaults.set(adblockCookiesEnabled, forKey: Keys.adblockCookiesEnabled) }
    }
    /// Block other annoyances via Fanboy's Annoyances. Default off — broad
    /// catch-all that occasionally hides genuine page content.
    var adblockAnnoyancesEnabled: Bool {
        didSet { defaults.set(adblockAnnoyancesEnabled, forKey: Keys.adblockAnnoyancesEnabled) }
    }
    /// Per-site allowlist: top-level frame domains for which all adblock
    /// categories are bypassed (the page sees the unblocked web). Stored
    /// normalized — lowercase, leading `www.` stripped — so user toggles on
    /// `www.nytimes.com` and a typed entry of `nytimes.com` produce the
    /// same canonical entry.
    var adblockAllowlist: [String] {
        didSet { defaults.set(adblockAllowlist, forKey: Keys.adblockAllowlist) }
    }
    /// Keep filter lists fresh from the Swarm update feed. Default on; a
    /// no-op until the feed trust anchor is compiled in (AdblockUpdateFeed).
    var adblockAutoUpdateEnabled: Bool {
        didSet { defaults.set(adblockAutoUpdateEnabled, forKey: Keys.adblockAutoUpdateEnabled) }
    }
    /// Whether the embedded Swarm (bee) node should be running. User-
    /// togglable from the Swarm node sheet. Default true preserves the
    /// historical behavior. False means the node never starts on app
    /// launch and `bzz://` page loads fail until re-enabled.
    var swarmNodeEnabled: Bool {
        didSet { defaults.set(swarmNodeEnabled, forKey: Keys.swarmNodeEnabled) }
    }
    /// Whether the embedded IPFS reader should be running. User-
    /// togglable from the IPFS node sheet. Default **true** — the
    /// Rust reader is lightweight enough to run alongside Bee on
    /// mobile without measurable user-visible cost, and starting it
    /// on launch means `ipfs://` / `ipns://` loads (including the
    /// ENS-dispatched paths) work immediately. Users who explicitly
    /// toggled the setting in either direction keep their persisted
    /// value via `UserDefaults`.
    var ipfsNodeEnabled: Bool {
        didSet { defaults.set(ipfsNodeEnabled, forKey: Keys.ipfsNodeEnabled) }
    }
    /// Whether the embedded Myotis Ethereum light client should be
    /// running (mainnet + Gnosis). Default **true** — it is the app's
    /// strongest verification tier and every resolution path falls
    /// through to Colibri/quorum whenever it can't answer, so keeping it
    /// on has no availability cost. The toggle is the kill switch for
    /// networks where P2P is hostile.
    var myotisNodeEnabled: Bool {
        didSet { defaults.set(myotisNodeEnabled, forKey: Keys.myotisNodeEnabled) }
    }
    /// Whether the embedded Radicle node should be running. Default
    /// **true** on this branch so the publish path is exercisable
    /// out of the box; the toggle is the kill switch (and the
    /// `window.radicle` provider reports `integration-disabled` while
    /// off, matching desktop's experimental setting).
    var radicleNodeEnabled: Bool {
        didSet { defaults.set(radicleNodeEnabled, forKey: Keys.radicleNodeEnabled) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.ensRpcUrl: "",
            Keys.ensResolutionMethod: ENSResolutionMethod.colibri.rawValue,
            Keys.ensFallbackToQuorum: true,
            Keys.ensPreferVerified: true,
            Keys.ensColibriProverUrl: "",
            Keys.ensColibriZkProof: true,
            Keys.enableEnsQuorum: true,
            Keys.ensQuorumK: 3,
            Keys.ensQuorumM: 2,
            Keys.ensQuorumTimeoutMs: 5_000,
            Keys.ensBlockAnchor: BlockAnchor.latest.rawValue,
            Keys.ensBlockAnchorTtlMs: 30_000,
            Keys.ensPublicRpcProviders: Self.defaultPublicRpcProviders,
            Keys.blockUnverifiedEns: true,
            Keys.enableCcipRead: true,
            Keys.beeNodeMode: BeeNodeMode.ultraLight.rawValue,
            Keys.hasCompletedPublishSetup: false,
            Keys.ipfsRoutingMode: IPFSRoutingMode.autoclient.rawValue,
            Keys.ipfsLowPower: false,
            Keys.adblockAdsEnabled: true,
            Keys.adblockPrivacyEnabled: true,
            Keys.adblockCookiesEnabled: false,
            Keys.adblockAnnoyancesEnabled: false,
            Keys.adblockAllowlist: [String](),
            Keys.adblockAutoUpdateEnabled: true,
            Keys.swarmNodeEnabled: true,
            Keys.ipfsNodeEnabled: true,
            Keys.myotisNodeEnabled: true,
            Keys.radicleNodeEnabled: true,
        ])
        self.ensRpcUrl = defaults.string(forKey: Keys.ensRpcUrl) ?? ""
        self.ensColibriProverUrl = defaults.string(forKey: Keys.ensColibriProverUrl) ?? ""
        self.ensColibriZkProof = defaults.bool(forKey: Keys.ensColibriZkProof)
        self.ensPreferVerified = defaults.object(forKey: Keys.ensPreferVerified) as? Bool ?? true
        let (order, enabled) = Self.migratedResolutionOrder(defaults: defaults)
        self.ensResolutionOrder = order
        self.ensResolutionEnabled = enabled
        self.ensQuorumK = defaults.integer(forKey: Keys.ensQuorumK)
        self.ensQuorumM = defaults.integer(forKey: Keys.ensQuorumM)
        self.ensQuorumTimeoutMs = defaults.integer(forKey: Keys.ensQuorumTimeoutMs)
        self.ensBlockAnchor = defaults.string(forKey: Keys.ensBlockAnchor)
            .flatMap(BlockAnchor.init(rawValue:)) ?? .latest
        self.ensBlockAnchorTtlMs = defaults.integer(forKey: Keys.ensBlockAnchorTtlMs)
        self.ensPublicRpcProviders = defaults.stringArray(forKey: Keys.ensPublicRpcProviders)
            ?? Self.defaultPublicRpcProviders
        self.chainStoreMigrated = defaults.bool(forKey: Keys.chainStoreMigrated)
        self.blockUnverifiedEns = defaults.bool(forKey: Keys.blockUnverifiedEns)
        self.enableCcipRead = defaults.bool(forKey: Keys.enableCcipRead)
        self.beeNodeMode = defaults.string(forKey: Keys.beeNodeMode)
            .flatMap(BeeNodeMode.init(rawValue:)) ?? .ultraLight
        self.hasCompletedPublishSetup = defaults.bool(forKey: Keys.hasCompletedPublishSetup)
        self.ipfsRoutingMode = defaults.string(forKey: Keys.ipfsRoutingMode)
            .flatMap(IPFSRoutingMode.init(rawValue:)) ?? .autoclient
        self.ipfsLowPower = defaults.bool(forKey: Keys.ipfsLowPower)
        self.adblockAdsEnabled = defaults.bool(forKey: Keys.adblockAdsEnabled)
        self.adblockPrivacyEnabled = defaults.bool(forKey: Keys.adblockPrivacyEnabled)
        self.adblockCookiesEnabled = defaults.bool(forKey: Keys.adblockCookiesEnabled)
        self.adblockAnnoyancesEnabled = defaults.bool(forKey: Keys.adblockAnnoyancesEnabled)
        self.adblockAllowlist = defaults.stringArray(forKey: Keys.adblockAllowlist) ?? []
        self.adblockAutoUpdateEnabled = defaults.bool(forKey: Keys.adblockAutoUpdateEnabled)
        self.swarmNodeEnabled = defaults.bool(forKey: Keys.swarmNodeEnabled)
        self.ipfsNodeEnabled = defaults.bool(forKey: Keys.ipfsNodeEnabled)
        self.myotisNodeEnabled = defaults.bool(forKey: Keys.myotisNodeEnabled)
        self.radicleNodeEnabled = defaults.bool(forKey: Keys.radicleNodeEnabled)
    }

    /// One-time migration for installs predating the `ensResolutionMethod`
    /// key. Custom-RPC users deliberately pointed Freedom at their own
    /// node — preserve that on `.userConfigured`. Everyone else (including
    /// fresh installs, where `enableEnsCustomRpc` is false) moves to the
    /// cryptographically-verified `.colibri` path. Idempotent: once the
    /// marker is set, the persisted `ensResolutionMethod` is authoritative
    /// and a later user choice in settings isn't clobbered.
    private static func migratedResolutionMethod(defaults: UserDefaults) -> ENSResolutionMethod {
        if defaults.bool(forKey: Keys.ensResolutionMethodMigrated) {
            return defaults.string(forKey: Keys.ensResolutionMethod)
                .flatMap(ENSResolutionMethod.init(rawValue:)) ?? .colibri
        }
        let method: ENSResolutionMethod =
            defaults.bool(forKey: Keys.enableEnsCustomRpc) ? .userConfigured : .colibri
        defaults.set(method.rawValue, forKey: Keys.ensResolutionMethod)
        defaults.set(true, forKey: Keys.ensResolutionMethodMigrated)
        return method
    }

    /// One-time migration to the ordered resolution policy. Installs
    /// that already carry an order keep it; older ones derive it from
    /// the single-method picker and its two switches so behaviour does
    /// not change on update: Colibri primary → Myotis, Colibri, quorum
    /// (quorum only if the fallback switch was on); quorum primary →
    /// Myotis, quorum; custom RPC → Myotis, Direct RPC, quorum. A
    /// disabled quorum switch turns Direct RPC on in its place, which
    /// is what the old single-source degrade did. Custom-RPC users keep
    /// their node as the only RPC method (fail-closed, as before).
    private static func migratedResolutionOrder(
        defaults: UserDefaults
    ) -> ([ENSResolutionMethod], Set<ENSResolutionMethod>) {
        if defaults.bool(forKey: Keys.ensResolutionOrderMigrated),
           let rawOrder = defaults.stringArray(forKey: Keys.ensResolutionOrder),
           let rawEnabled = defaults.stringArray(forKey: Keys.ensResolutionEnabled) {
            let order = normalizedOrder(rawOrder.compactMap(ENSResolutionMethod.init(rawValue:)))
            let enabled = Set(rawEnabled.compactMap(ENSResolutionMethod.init(rawValue:)))
                .intersection(resolutionMethods)
            return (order, enabled)
        }
        let primary = migratedResolutionMethod(defaults: defaults)
        let quorumSwitch = defaults.bool(forKey: Keys.enableEnsQuorum)
        let fallbackSwitch = defaults.bool(forKey: Keys.ensFallbackToQuorum)
        var order: [ENSResolutionMethod] = [.myotis]
        var enabled: Set<ENSResolutionMethod> = [.myotis]
        switch primary {
        case .userConfigured, .direct:
            // Fail-closed privacy choice: the user's node only, no public
            // fallback (desktop's legacyOrder adds quorum; iOS never did).
            order += [.userConfigured, .quorum]
            enabled.insert(.userConfigured)
        case .quorum:
            order += [.quorum]
            if quorumSwitch { enabled.insert(.quorum) } else { enabled.insert(.userConfigured) }
        case .colibri, .myotis:
            order += [.colibri, .quorum]
            enabled.insert(.colibri)
            if quorumSwitch && fallbackSwitch { enabled.insert(.quorum) }
        }
        order = normalizedOrder(order)
        defaults.set(order.map(\.rawValue), forKey: Keys.ensResolutionOrder)
        defaults.set(enabled.map(\.rawValue).sorted(), forKey: Keys.ensResolutionEnabled)
        defaults.set(true, forKey: Keys.ensResolutionOrderMigrated)
        return (order, enabled)
    }

    /// Materialize current IPFS settings into an `IPFSConfig` ready for
    /// `IPFSNode.start` / `restart`. The data dir, gateway host, and
    /// gateway port aren't user-configurable yet; defaults from
    /// `IPFSConfig.init` apply.
    func ipfsConfig(dataDir: URL) -> IPFSConfig {
        IPFSConfig(
            dataDir: dataDir,
            lowPower: ipfsLowPower,
            routingMode: ipfsRoutingMode,
            // Give queued native requests up to 15s to win an admission
            // slot before the bounded gateway returns `gateway_busy` —
            // the desktop high-fanout fix. Heavy pages fire 40–80
            // subresources at once; without this, the overflow instantly
            // 503s under admission pressure and renders blank. This only
            // makes admission more patient; it does NOT widen the gateway
            // (concurrency stays bounded — see maxConcurrentRequests).
            requestQueueTimeoutMilliseconds: 15_000
        )
    }

    private enum Keys {
        static let enableEnsCustomRpc = "enableEnsCustomRpc"
        static let ensRpcUrl = "ensRpcUrl"
        static let ensResolutionMethod = "ensResolutionMethod"
        static let ensResolutionMethodMigrated = "ensResolutionMethodMigrated"
        static let ensFallbackToQuorum = "ensFallbackToQuorum"
        static let ensResolutionOrder = "ensResolutionOrder"
        static let ensResolutionEnabled = "ensResolutionEnabled"
        static let ensResolutionOrderMigrated = "ensResolutionOrderMigrated"
        static let ensPreferVerified = "ensPreferVerified"
        static let ensColibriProverUrl = "ensColibriProverUrl"
        static let ensColibriZkProof = "ensColibriZkProof"
        static let enableEnsQuorum = "enableEnsQuorum"
        static let ensQuorumK = "ensQuorumK"
        static let ensQuorumM = "ensQuorumM"
        static let ensQuorumTimeoutMs = "ensQuorumTimeoutMs"
        static let ensBlockAnchor = "ensBlockAnchor"
        static let ensBlockAnchorTtlMs = "ensBlockAnchorTtlMs"
        static let ensPublicRpcProviders = "ensPublicRpcProviders"
        static let chainStoreMigrated = "chainStoreMigrated"
        static let blockUnverifiedEns = "blockUnverifiedEns"
        static let enableCcipRead = "enableCcipRead"
        static let beeNodeMode = "beeNodeMode"
        static let hasCompletedPublishSetup = "hasCompletedPublishSetup"
        static let ipfsRoutingMode = "ipfsRoutingMode"
        static let ipfsLowPower = "ipfsLowPower"
        static let adblockAdsEnabled = "adblockAdsEnabled"
        static let adblockPrivacyEnabled = "adblockPrivacyEnabled"
        static let adblockCookiesEnabled = "adblockCookiesEnabled"
        static let adblockAnnoyancesEnabled = "adblockAnnoyancesEnabled"
        static let adblockAllowlist = "adblockAllowlist"
        static let adblockAutoUpdateEnabled = "adblockAutoUpdateEnabled"
        static let swarmNodeEnabled = "swarmNodeEnabled"
        static let ipfsNodeEnabled = "ipfsNodeEnabled"
        static let myotisNodeEnabled = "myotisNodeEnabled"
        static let radicleNodeEnabled = "radicleNodeEnabled"
    }
}
