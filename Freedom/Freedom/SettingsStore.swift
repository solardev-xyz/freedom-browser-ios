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
    static let defaultPublicRpcProviders: [String] = [
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

    var enableEnsCustomRpc: Bool {
        didSet { defaults.set(enableEnsCustomRpc, forKey: Keys.enableEnsCustomRpc) }
    }
    var ensRpcUrl: String {
        didSet { defaults.set(ensRpcUrl, forKey: Keys.ensRpcUrl) }
    }
    var enableEnsQuorum: Bool {
        didSet { defaults.set(enableEnsQuorum, forKey: Keys.enableEnsQuorum) }
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
    var blockUnverifiedEns: Bool {
        didSet { defaults.set(blockUnverifiedEns, forKey: Keys.blockUnverifiedEns) }
    }
    var enableCcipRead: Bool {
        didSet { defaults.set(enableCcipRead, forKey: Keys.enableCcipRead) }
    }
    var beeNodeMode: BeeNodeMode {
        didSet { defaults.set(beeNodeMode.rawValue, forKey: Keys.beeNodeMode) }
    }
    /// kubo content-routing mode. `.autoclient` is the default —
    /// delegated-routing + light DHT client, the cheapest reachable
    /// configuration on mobile.
    var ipfsRoutingMode: IPFSRoutingMode {
        didSet { defaults.set(ipfsRoutingMode.rawValue, forKey: Keys.ipfsRoutingMode) }
    }
    /// Whether kubo runs with reduced libp2p connection/stream limits
    /// (DHT server off, smaller pools). Right setting for mobile by
    /// default; advanced users can disable for a fuller swarm presence.
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
    /// Whether the embedded Swarm (bee) node should be running. User-
    /// togglable from the Swarm node sheet. Default true preserves the
    /// historical behavior. False means the node never starts on app
    /// launch and `bzz://` page loads fail until re-enabled.
    var swarmNodeEnabled: Bool {
        didSet { defaults.set(swarmNodeEnabled, forKey: Keys.swarmNodeEnabled) }
    }
    /// Whether the embedded IPFS (kubo) node should be running. User-
    /// togglable from the IPFS node sheet. Default **false** as a
    /// short-term performance fix — running both nodes in parallel
    /// degrades phone responsiveness too much before the lighter
    /// node clients land. False means the node never starts on app
    /// launch and `ipfs://` / `ipns://` page loads (including ENS-
    /// dispatched ones) fail until re-enabled.
    var ipfsNodeEnabled: Bool {
        didSet { defaults.set(ipfsNodeEnabled, forKey: Keys.ipfsNodeEnabled) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.enableEnsCustomRpc: false,
            Keys.ensRpcUrl: "",
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
            Keys.ipfsLowPower: true,
            Keys.adblockAdsEnabled: true,
            Keys.adblockPrivacyEnabled: true,
            Keys.adblockCookiesEnabled: false,
            Keys.adblockAnnoyancesEnabled: false,
            Keys.adblockAllowlist: [String](),
            Keys.swarmNodeEnabled: true,
            Keys.ipfsNodeEnabled: false,
        ])
        self.enableEnsCustomRpc = defaults.bool(forKey: Keys.enableEnsCustomRpc)
        self.ensRpcUrl = defaults.string(forKey: Keys.ensRpcUrl) ?? ""
        self.enableEnsQuorum = defaults.bool(forKey: Keys.enableEnsQuorum)
        self.ensQuorumK = defaults.integer(forKey: Keys.ensQuorumK)
        self.ensQuorumM = defaults.integer(forKey: Keys.ensQuorumM)
        self.ensQuorumTimeoutMs = defaults.integer(forKey: Keys.ensQuorumTimeoutMs)
        self.ensBlockAnchor = defaults.string(forKey: Keys.ensBlockAnchor)
            .flatMap(BlockAnchor.init(rawValue:)) ?? .latest
        self.ensBlockAnchorTtlMs = defaults.integer(forKey: Keys.ensBlockAnchorTtlMs)
        self.ensPublicRpcProviders = defaults.stringArray(forKey: Keys.ensPublicRpcProviders)
            ?? Self.defaultPublicRpcProviders
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
        self.swarmNodeEnabled = defaults.bool(forKey: Keys.swarmNodeEnabled)
        self.ipfsNodeEnabled = defaults.bool(forKey: Keys.ipfsNodeEnabled)
    }

    /// Materialize current IPFS settings into an `IPFSConfig` ready for
    /// `IPFSNode.start` / `restart`. The data dir, gateway host, and
    /// gateway port aren't user-configurable yet; defaults from
    /// `IPFSConfig.init` apply.
    func ipfsConfig(dataDir: URL) -> IPFSConfig {
        IPFSConfig(
            dataDir: dataDir,
            lowPower: ipfsLowPower,
            routingMode: ipfsRoutingMode
        )
    }

    private enum Keys {
        static let enableEnsCustomRpc = "enableEnsCustomRpc"
        static let ensRpcUrl = "ensRpcUrl"
        static let enableEnsQuorum = "enableEnsQuorum"
        static let ensQuorumK = "ensQuorumK"
        static let ensQuorumM = "ensQuorumM"
        static let ensQuorumTimeoutMs = "ensQuorumTimeoutMs"
        static let ensBlockAnchor = "ensBlockAnchor"
        static let ensBlockAnchorTtlMs = "ensBlockAnchorTtlMs"
        static let ensPublicRpcProviders = "ensPublicRpcProviders"
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
        static let swarmNodeEnabled = "swarmNodeEnabled"
        static let ipfsNodeEnabled = "ipfsNodeEnabled"
    }
}
