import Foundation
import SwarmKit

/// Aggregates "what's the bee node's publishing readiness right now" into
/// a single observable enum. Drives:
///   - the status-bar suffix in `ContentView` (always-visible hint)
///   - the checklist progression in `PublishSetupView` (full surface)
///
/// Adaptive polling: 3s while light mode is not-yet-ready (so the live
/// percent feels responsive), 30s once `.ready` (sticky).
@MainActor
@Observable
final class BeeReadiness {
    enum State: Equatable {
        /// Ultralight — node is browsing-only. No publishing surface.
        case browsingOnly
        /// Light, but bee isn't running yet (booting, restart in flight).
        case initializing
        /// Light + running, but bee's API is in its "Node is syncing"
        /// phase — `/chainstate` not yet reachable, every other endpoint
        /// 503s. Brief; we usually skip straight to `.syncingPostage`.
        case startingUp
        /// Light + running, `/chainstate` reachable. `block / chainTip`
        /// gives a smooth percent during the bundled-snapshot ingest
        /// (most of the ~5min wait happens here).
        case syncingPostage(percent: Int, lastSynced: Int, chainHead: Int)
        /// Light + running + `/readiness` reports ready. Chequebook
        /// subsystem is online; `chequebookAddress` is populated.
        case ready
    }

    private(set) var state: State = .browsingOnly
    /// Bee's chequebook contract address, fetched once when the node
    /// first transitions to `.ready`. Drives the publish-setup
    /// "Chequebook deployed" confirmation row.
    private(set) var chequebookAddress: String?

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

    /// Idempotent — re-entry cancels the prior task. The poll cadence
    /// flips between `activeIntervalSeconds` (light + not ready) and
    /// `idleIntervalSeconds` (everything else) automatically; callers
    /// don't need to manually retune for setup vs background.
    func start(
        activeIntervalSeconds: TimeInterval = 3,
        idleIntervalSeconds: TimeInterval = 30
    ) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let active = await self?.shouldPollFast() ?? false
                let interval = active ? activeIntervalSeconds : idleIntervalSeconds
                let nanos = UInt64(max(1, interval) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Safe to call from anywhere — coalesces under `state`'s observation.
    func refresh() async {
        let wasReady = state == .ready
        let next = await computeState()
        if next != state { state = next }
        // First time we cross into .ready: bee's chequebook subsystem is
        // online so `/chequebook/address` responds. Fetch once for the
        // publish-setup checklist's "Chequebook deployed" row.
        // (Stamps live in `StampService`, which polls independently.)
        if !wasReady && next == .ready {
            chequebookAddress = await fetchChequebookAddress()
        }
        // Sticky flag: once the user has crossed into .ready we know
        // statestore has the chequebook reference (`restartForMode`
        // never wipes), so the inline mode toggle in `NodeHomeView` is
        // safe to surface even after they later flip back to ultralight.
        if next == .ready && !settings.hasCompletedPublishSetup {
            settings.hasCompletedPublishSetup = true
        }
    }

    // MARK: - Private

    private func shouldPollFast() -> Bool {
        guard settings.beeNodeMode == .light else { return false }
        return state != .ready
    }

    private func computeState() async -> State {
        guard settings.beeNodeMode == .light else { return .browsingOnly }
        // `.starting` matters: `SwarmNode.start` does a blocking gomobile
        // call that doesn't return — and so doesn't set `.running` —
        // until bee's full init (including the ~5min bundled-snapshot
        // ingest) completes. Bee's HTTP server is up the whole time, so
        // we want to poll it during `.starting` to surface the live
        // percent. Without this, step 2 sits on its initializing copy
        // for the entire wait and the user sees no progress.
        guard swarm.status == .running || swarm.status == .starting else {
            return .initializing
        }
        // .ready is sticky — only mode flip / restart resets it, both
        // caught by the guards above. Skipping the API calls here
        // eliminates the dominant idle cost.
        if state == .ready { return .ready }

        // Bee's own /readiness signal is the ground truth — accounts for
        // chequebook subsystem online + warmup + sync caught up to chain
        // head in one signal.
        if await isBeeReady() { return .ready }

        if let progress = await fetchChainProgress() {
            return .syncingPostage(
                percent: progress.percent,
                lastSynced: progress.block,
                chainHead: progress.chainTip
            )
        }
        // Bee alive but `/chainstate` not yet reachable — very early
        // init, before bee has hooked up the chain backend.
        return .startingUp
    }

    private func isBeeReady() async -> Bool {
        guard let dict = try? await bee.getJSON("/readiness"),
              let status = dict["status"] as? String else { return false }
        return status == "ready"
    }

    private struct ChainProgress {
        let percent: Int
        let block: Int
        let chainTip: Int
    }

    /// `/chainstate` returns `{block, chainTip, ...}` and stays available
    /// for the whole startup window — including the bundled-snapshot
    /// processing phase where every other endpoint replies 503 with
    /// "Node is syncing." `block` advances ~30K events/sec as bee chews
    /// the snapshot, `chainTip` tracks the live chain.
    private func fetchChainProgress() async -> ChainProgress? {
        guard let dict = try? await bee.getJSON("/chainstate") else {
            return nil
        }
        guard let block = BeeAPIClient.intFromAnyJSON(dict["block"]),
              let chainTip = BeeAPIClient.intFromAnyJSON(dict["chainTip"]),
              chainTip > 0 else {
            return nil
        }
        // Truncate so we never spuriously hit 100 before /readiness flips.
        let percent = Int(Double(block) / Double(chainTip) * 100.0)
        return ChainProgress(percent: percent, block: block, chainTip: chainTip)
    }

    private func fetchChequebookAddress() async -> String? {
        guard let dict = try? await bee.getJSON("/chequebook/address"),
              let addr = dict["chequebookAddress"] as? String else {
            return nil
        }
        let stripped = Hex.stripped(addr).lowercased()
        guard !stripped.isEmpty, !stripped.allSatisfy({ $0 == "0" }) else {
            return nil
        }
        return Hex.prefixed(addr)
    }

}
