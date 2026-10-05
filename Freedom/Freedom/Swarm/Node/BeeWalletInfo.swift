import BigInt
import Foundation
import SwarmKit

/// Polls bee for the node wallet's xDAI/xBZZ balances and the
/// chequebook's available xBZZ. Drives the node-sheet wallet/
/// chequebook cards. Polled every 30s while in light mode — wallet
/// balances move slowly, no need for the adaptive cadence
/// `BeeReadiness` and `StampService` use.
@MainActor
@Observable
final class BeeWalletInfo {
    /// Bee node's native (xDAI on Gnosis) balance, in wei. Nil until
    /// bee is past the "Node is syncing" window — `/wallet` 503s during
    /// the bundled-snapshot ingest like every other endpoint.
    private(set) var nodeXdai: BigUInt?
    /// Bee node's xBZZ balance, in PLUR (1 BZZ = 1e16 PLUR).
    private(set) var nodeXbzz: BigUInt?
    /// xBZZ currently spendable by the chequebook (the "available"
    /// half of bee's `totalBalance / availableBalance` split). Nil
    /// while the chequebook subsystem isn't yet online.
    private(set) var chequebookXbzz: BigUInt?
    /// The running node's `/wallet` was read at least once: until then a
    /// missing balance is "loading", afterwards "not available". Reset
    /// whenever the node is not running.
    private(set) var hasLoaded = false

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let bee: BeeAPIClient
    @ObservationIgnored private let swarm: SwarmNode
    @ObservationIgnored private let settings: SettingsStore

    init(
        swarm: SwarmNode,
        settings: SettingsStore,
        bee: BeeAPIClient = BeeAPIClient()
    ) {
        self.swarm = swarm
        self.settings = settings
        self.bee = bee
    }

    /// Idempotent — re-entry cancels prior task. Retries every
    /// `loadingIntervalSeconds` until the first read succeeds, so the
    /// balances appear as soon as the node answers.
    func start(intervalSeconds: TimeInterval = 30, loadingIntervalSeconds: TimeInterval = 2) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let loading = await !(self?.hasLoaded ?? true)
                let seconds = loading ? loadingIntervalSeconds : intervalSeconds
                try? await Task.sleep(nanoseconds: UInt64(max(1, seconds) * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Pull fresh balances. Falls through silently on errors — the
    /// next tick will retry.
    func refresh() async {
        if swarm.status != .running, hasLoaded { hasLoaded = false }
        var walletRead = false
        if let dict = try? await bee.getJSON("/wallet") {
            walletRead = true
            let xdai = Self.parseBig(dict["nativeTokenBalance"])
            if let xdai, xdai != nodeXdai { nodeXdai = xdai }
            let xbzz = Self.parseBig(dict["bzzBalance"])
            if let xbzz, xbzz != nodeXbzz { nodeXbzz = xbzz }
        }
        if let dict = try? await bee.getJSON("/chequebook/balance") {
            let xbzz = Self.parseBig(dict["availableBalance"])
            if let xbzz, xbzz != chequebookXbzz { chequebookXbzz = xbzz }
        }
        // After both reads, so the chequebook row never flashes "—".
        if walletRead, !hasLoaded { hasLoaded = true }
    }

    /// Bee returns balances as decimal-string PLUR/wei (the values
    /// can exceed `Int64.max`). Parse into `BigUInt`.
    private static func parseBig(_ value: Any?) -> BigUInt? {
        guard let s = value as? String else { return nil }
        return BigUInt(s, radix: 10)
    }
}
