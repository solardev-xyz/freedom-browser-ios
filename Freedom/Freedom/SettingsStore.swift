import Foundation

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
    }
}
