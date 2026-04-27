import Foundation
import SwarmKit

/// Aggregates "what's the bee node's publishing readiness right now" into
/// a single observable enum. Drives:
///   - the status-bar suffix in `ContentView` (always-visible hint)
///   - the checklist progression in `PublishSetupView` (full surface)
///
/// Polled separately from `SwarmNode.peerCount` (5s by default; faster
/// when the user is on the publish-setup screen). The polling task tears
/// down on `stop()` — callers wire it to scenePhase + view appearance.
@MainActor
@Observable
final class BeeReadiness {
    enum State: Equatable {
        /// Ultralight — node is browsing-only. No publishing surface.
        case browsingOnly
        /// Light, but bee isn't running yet (booting, restart in flight).
        case initializing
        /// Light + running, but the chequebook contract isn't deployed.
        /// Bee broadcasts the deploy tx as soon as the wallet has xDAI;
        /// this state typically lasts 1-2 minutes.
        case deployingChequebook
        /// Light + running + chequebook deployed, but historical postage
        /// data is still syncing from Gnosis. Can take up to ~20 minutes
        /// on a fresh node. Progress is best-effort: `chainHead == 0`
        /// means we couldn't read the chain head.
        case syncingPostage(percent: Int, lastSynced: Int, chainHead: Int)
        /// Light + running + chequebook + fully synced. Ready to publish
        /// (modulo stamps, which arrive via WP3).
        case ready
    }

    private(set) var state: State = .browsingOnly

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let bee: BeeAPIClient
    @ObservationIgnored private let walletRPC: WalletRPC
    @ObservationIgnored private let swarm: SwarmNode
    @ObservationIgnored private let settings: SettingsStore
    /// Gnosis chain head cache. The head moves ~5s/block but our percent
    /// only renders integers, so refreshing it inside a 30s polling loop
    /// is overkill. 60s TTL keeps the displayed % within 1 percent of
    /// reality at peak sync rate.
    @ObservationIgnored private var cachedChainHead: (block: Int, expiry: Date)?

    init(
        swarm: SwarmNode,
        settings: SettingsStore,
        walletRPC: WalletRPC,
        bee: BeeAPIClient = BeeAPIClient()
    ) {
        self.swarm = swarm
        self.settings = settings
        self.walletRPC = walletRPC
        self.bee = bee
    }

    /// Idempotent — re-entry cancels the prior task.
    func start(intervalSeconds: TimeInterval = 30) {
        pollTask?.cancel()
        let interval = UInt64(max(1, intervalSeconds) * 1_000_000_000)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Safe to call from anywhere — coalesces under `state`'s observation.
    func refresh() async {
        let next = await computeState()
        if next != state { state = next }
        // Sticky flag: once the user has crossed into .ready we know
        // statestore has the chequebook reference (`restartForMode`
        // never wipes), so the inline mode toggle in `NodeHomeView` is
        // safe to surface even after they later flip back to ultralight.
        if next == .ready && !settings.hasCompletedPublishSetup {
            settings.hasCompletedPublishSetup = true
        }
    }

    // MARK: - Private

    private func computeState() async -> State {
        guard settings.beeNodeMode == .light else { return .browsingOnly }
        guard swarm.status == .running else { return .initializing }
        // Chequebook deploy + postage sync are monotonic-forward — once
        // ready, the only way to leave .ready is via a mode flip or node
        // restart, both of which the guards above catch first. Skipping
        // the API calls here eliminates the dominant idle cost (was ~3
        // calls/30s including a Gnosis RPC, forever).
        if state == .ready { return .ready }

        // Bee's own /readiness signal is the ground truth — it accounts
        // for chequebook + warmup + sync caught up to chain head in one
        // signal. Our derived sync % is for *progress display* only.
        if await isBeeReady() { return .ready }

        async let chequebookDeployed = isChequebookDeployed()
        async let progress = fetchSyncProgress()

        let deployed = await chequebookDeployed
        guard deployed else { return .deployingChequebook }

        if let p = await progress {
            return .syncingPostage(
                percent: p.percent,
                lastSynced: p.lastSynced,
                chainHead: p.chainHead
            )
        }
        // Chequebook deployed, but no /status data yet — show 0% rather
        // than dropping back to .deployingChequebook (we know the deploy
        // is done; we just don't have sync data yet).
        return .syncingPostage(percent: 0, lastSynced: 0, chainHead: 0)
    }

    private func isBeeReady() async -> Bool {
        guard let dict = try? await bee.getJSON("/readiness"),
              let status = dict["status"] as? String else { return false }
        return status == "ready"
    }

    /// `/chequebook/address` returns `{ chequebookAddress: "0x..." }`.
    /// All-zeros means the contract hasn't been deployed yet; bee returns
    /// the zero address rather than 404 in that case.
    private func isChequebookDeployed() async -> Bool {
        guard let dict = try? await bee.getJSON("/chequebook/address"),
              let addr = dict["chequebookAddress"] as? String else {
            return false
        }
        let stripped = Hex.stripped(addr).lowercased()
        return !stripped.isEmpty && !stripped.allSatisfy { $0 == "0" }
    }

    private struct SyncProgress {
        let percent: Int
        let lastSynced: Int
        let chainHead: Int
    }

    /// `/status` carries `lastSyncedBlock`; we cross-reference it against
    /// the Gnosis chain head (cached, see `cachedChainHead`) to get a
    /// percent. Nil if either query failed (caller treats absence as
    /// "still syncing, no progress info").
    private func fetchSyncProgress() async -> SyncProgress? {
        guard let dict = try? await bee.getJSON("/status"),
              let lastSyncedRaw = dict["lastSyncedBlock"] else {
            return nil
        }
        let lastSynced = Self.intFromAnyJSON(lastSyncedRaw) ?? 0
        let head = await fetchChainHead()

        // Display-only — readiness gate runs off `/readiness`, not this
        // percent. `Int(...)` truncates so we never spuriously hit 100
        // before bee says it's ready.
        let percent: Int
        if head > 0 && lastSynced > 0 {
            percent = Int(Double(lastSynced) / Double(head) * 100.0)
        } else {
            percent = 0
        }
        return SyncProgress(percent: percent, lastSynced: lastSynced, chainHead: head)
    }

    /// Read Gnosis chain head, reusing a cached value within its TTL.
    /// Returns 0 if the call fails (caller falls back to a percent-less
    /// progress display).
    private func fetchChainHead() async -> Int {
        if let cached = cachedChainHead, cached.expiry > Date() {
            return cached.block
        }
        guard let hex = try? await walletRPC.blockNumber(on: .gnosis),
              let parsed = Hex.int(hex) else {
            return 0
        }
        cachedChainHead = (parsed, Date().addingTimeInterval(60))
        return parsed
    }

    /// Bee returns `lastSyncedBlock` as either a JSON number or string
    /// depending on version; collapse both into `Int?`.
    private static func intFromAnyJSON(_ value: Any) -> Int? {
        if let int = value as? Int { return int }
        if let int64 = value as? Int64 { return Int(int64) }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
