import Foundation
import Observation
import OSLog
import FreedomMobile

/// Mirrors the in-app ring log so `log stream --predicate 'subsystem ==
/// "com.browser.Freedom" AND category == "MyotisNode"'` can follow the
/// engine + recovery lifecycle from the host (smoke tests, field logs).
private nonisolated let nodeLog = Logger(subsystem: "com.browser.Freedom", category: "MyotisNode")

/// `MyotisNode` is a thin Swift facade over the Rust **Myotis** engine
/// (`myotis-engine`, `myotis_*` C ABI) — a fully peer-to-peer Ethereum
/// light client: devp2p on the execution layer (discv4/RLPx/eth/snap),
/// libp2p beacon light client on the consensus layer, every read
/// Merkle-proven against a sync-committee-anchored state root. No HTTP
/// API, no managed port: reads go through the C ABI in-process.
///
/// One `MyotisNode` owns one engine handle **per network** (mainnet +
/// gnosis). Unlike `SwarmNode`/`IPFSNode` there is no gateway to bind:
/// lifecycle is create → start → (pause/resume on scenePhase) → stop,
/// and the interesting state is per-chain *availability* — whether
/// verified reads can be served right now (see `isReady(chainId:)`).
///
/// Stale-anchor recovery (desktop PR #353 parity): when the engine parks
/// a chain in `STALE_ANCHOR` (its trust anchor is past the
/// weak-subjectivity bound) the node obtains a fresh checkpoint through
/// an external quorum corroborated by a Colibri proof
/// (`MyotisCheckpointAcquirer`), stops the parked engine, mints a fresh
/// verified generation (`MyotisGenerationStore`) and bootstraps from the
/// checkpoint (`myotis_create_with_checkpoint`). Verified reads stay off
/// until the engine completes normal sync from that anchor. The node
/// never calls `myotis_accept_stale_anchor` or raises the bound.
public enum MyotisStatus: String, Sendable {
    case idle, starting, running, stopping, stopped, failed
}

/// A supported network. Raw value is the engine's canonical network name
/// (`myotis_create` input); `chainId` is what resolution code keys on.
public enum MyotisNetwork: String, CaseIterable, Sendable {
    case mainnet
    case gnosis

    public var chainId: UInt64 {
        switch self {
        case .mainnet: 1
        case .gnosis: 100
        }
    }

    public static func forChain(_ chainId: UInt64) -> MyotisNetwork? {
        allCases.first { $0.chainId == chainId }
    }
}

/// Decoded subset of `myotis_status_json`, published per network.
public struct MyotisChainStatus: Sendable, Equatable {
    public var beaconState: String = ""
    public var peerCount: Int = 0
    public var snapPeers: Int = 0
    public var executionBlockNumber: Int64 = 0
    public var finalizedBlockNumber: Int64 = 0
    public var running: Bool = false
    public var paused: Bool = false
    /// Finalized beacon header slot + hash_tree_root (ABI 26). What the
    /// recovery finish check binds against the anchored checkpoint.
    public var finalizedSlot: UInt64 = 0
    public var finalizedRootHex: String = ""
    public var currentPeriod: UInt64 = 0
    public var targetPeriod: UInt64 = 0
    /// Weak-subjectivity bound (periods) the engine enforces. While
    /// `STALE_ANCHOR`, `targetPeriod - currentPeriod` is the anchor age
    /// judged against it.
    public var wsBoundPeriods: UInt64 = 0
    /// EL reader up (vs. failed to start — the CL-only degraded mode).
    public var elReaderAvailable: Bool = true
    /// LC hunt engaged (starved of light-client servers). Display only:
    /// a SYNCED chain keeps serving verified reads during an LC hunt.
    public var lcHunting: Bool = false
    /// EL reader hunting for a servable head context. First reads during
    /// a hunt fail on the cold context — desktop gates readiness on it.
    public var elHunting: Bool = false

    /// The engine's own park state: trust anchor past the bound.
    public var isStaleAnchor: Bool { beaconState == "STALE_ANCHOR" }

    /// Whether a verified read attempted now has a realistic chance of
    /// being answered. Beacon `SYNCED` alone is not enough: right after
    /// sync the EL side can still lack a snap peer, and every read fails
    /// with "state unavailable" / "no snap peer available" (observed in
    /// the Phase 0 spike). Gating on `snapPeers >= 1` skips the tier
    /// during that warm-up instead of burning a failed attempt per
    /// resolution. Desktop also requires the EL reader up and no EL hunt
    /// (first reads during a hunt fail on the cold context). The LC hunt
    /// flag is deliberately NOT a gate: on mainnet the light-client
    /// server pool is thin and the hunt stays engaged for long stretches
    /// while the chain is SYNCED and perfectly able to serve.
    public var ready: Bool {
        running && !paused && beaconState == "SYNCED" && snapPeers >= 1 && elReaderAvailable && !elHunting
    }

    /// Why a SYNCED chain is not serving — for the node log and the
    /// chain card. Empty when ready or not yet synced.
    public var notServingReason: String {
        guard running, !paused, beaconState == "SYNCED", !ready else { return "" }
        var reasons: [String] = []
        if snapPeers < 1 { reasons.append("no state peer") }
        if !elReaderAvailable { reasons.append("EL reader down") }
        if elHunting { reasons.append("EL hunting for a head") }
        return reasons.joined(separator: ", ")
    }

    public init() {}

    /// Decode the engine's status JSON (camelCase keys; `"{}"` for an
    /// unknown handle decodes to all-defaults, `ready == false`). Pure —
    /// unit-tested without a live engine.
    public static func decode(_ json: String) -> MyotisChainStatus {
        struct Raw: Decodable {
            var beaconState: String?
            var peerCount: Int?
            var snapPeers: Int?
            var executionBlockNumber: Int64?
            var finalizedBlockNumber: Int64?
            var running: Bool?
            var paused: Bool?
            var finalizedSlot: UInt64?
            var finalizedRootHex: String?
            var currentPeriod: UInt64?
            var targetPeriod: UInt64?
            var wsBoundPeriods: UInt64?
            var elReaderAvailable: Bool?
            var lcHunting: Bool?
            var elHunting: Bool?
        }
        var status = MyotisChainStatus()
        guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(json.utf8)) else {
            return status
        }
        status.beaconState = raw.beaconState ?? ""
        status.peerCount = raw.peerCount ?? 0
        status.snapPeers = raw.snapPeers ?? 0
        status.executionBlockNumber = raw.executionBlockNumber ?? 0
        status.finalizedBlockNumber = raw.finalizedBlockNumber ?? 0
        status.running = raw.running ?? false
        status.paused = raw.paused ?? false
        status.finalizedSlot = raw.finalizedSlot ?? 0
        status.finalizedRootHex = String((raw.finalizedRootHex ?? "").prefix(66))
        status.currentPeriod = raw.currentPeriod ?? 0
        status.targetPeriod = raw.targetPeriod ?? 0
        status.wsBoundPeriods = raw.wsBoundPeriods ?? 0
        status.elReaderAvailable = raw.elReaderAvailable ?? true
        status.lcHunting = raw.lcHunting ?? false
        status.elHunting = raw.elHunting ?? false
        return status
    }
}

/// Outcome of a verified `eth_call` through the engine. The JSON shapes
/// are pinned by the C header:
/// `{"status":"ok","resultHex"}` | `{"status":"revert","dataHex"}` |
/// `{"status":"unavailable","reason"}` | `{"error":"..."}`.
public enum MyotisCallOutcome: Sendable, Equatable {
    /// Executed over verified state; `resultHex` is the return data.
    case ok(resultHex: String)
    /// Executed over verified state and REVERTED — a *verified chain
    /// answer* (CCIP-Read, "no resolver", …), not a failure.
    case revert(dataHex: String)
    /// The node can't answer right now (not synced, no snap peer, head
    /// not anchored). Retryable — callers fall through to the next tier.
    case unavailable(reason: String)
    /// Transport/input failure ({"error"}). Fall through.
    case error(String)

    /// Pure decoder for the engine's call JSON — unit-tested without a
    /// live engine. Unknown shapes decode as `.error`.
    public static func decode(_ json: String) -> MyotisCallOutcome {
        struct Raw: Decodable {
            var status: String?
            var resultHex: String?
            var dataHex: String?
            var reason: String?
            var error: String?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(json.utf8)) else {
            return .error("undecodable engine response: \(json)")
        }
        if let error = raw.error { return .error(error) }
        switch raw.status {
        case "ok": return .ok(resultHex: raw.resultHex ?? "0x")
        case "revert": return .revert(dataHex: raw.dataHex ?? "0x")
        case "unavailable": return .unavailable(reason: raw.reason ?? "unavailable")
        default: return .error("unexpected engine response: \(json)")
        }
    }
}

@MainActor
@Observable
public final class MyotisNode {
    /// The engine ABI this wrapper was written against (myotis v0.1.10).
    /// `start()` refuses to run against any other — a stale framework
    /// would otherwise fail confusingly deep inside a resolve. ABI 26 is
    /// also the checkpoint-recovery capability signal
    /// (`myotis_create_with_checkpoint`).
    public static let expectedABI: Int32 = 26

    /// Live-set eth/69 served-block window. The engine default (32,
    /// ~16 KB per served request) suits a desktop; on a phone we serve
    /// the protocol minimum and keep the data budget for our own reads.
    public static let servedBlockWindow: Int32 = 1

    /// Status poll cadence. Desktop polls every second; the recovery
    /// ladder is coarse (15 s / 60 s) so a few seconds is plenty here.
    public static let pollIntervalSeconds: UInt64 = 3

    /// Engine create sentinels (myotis_engine.h).
    static let createFailed: Int64 = -1
    static let unsupportedNetwork: Int64 = -2
    static let anchorMismatch: Int64 = -3

    public private(set) var status: MyotisStatus = .idle
    /// Per-network engine status, keyed by chain ID (1, 100).
    public private(set) var chainStatus: [UInt64: MyotisChainStatus] = [:]
    /// Per-chain recovery state; `nil` when nothing is recovering or
    /// blocked. Drives the Nodes UI.
    public private(set) var recovery: [UInt64: MyotisRecoveryState] = [:]
    /// The generation each chain currently runs (origin + checkpoint).
    public private(set) var generations: [UInt64: MyotisGeneration] = [:]
    public private(set) var log: [String] = []

    /// Fired on every per-chain availability flip (`isReady` transitioned).
    /// The app hooks resolver-cache sweeps here so a freshly-ready node
    /// takes over immediately instead of waiting out cached TTLs.
    public var onAvailabilityChange: ((_ chainId: UInt64, _ ready: Bool) -> Void)?

    /// Host-side corroboration for checkpoint recovery (Colibri in the
    /// app). Without one, a stale anchor blocks with `unsupported`.
    public var checkpointCorroborator: MyotisCheckpointCorroborator?
    /// Bounded HTTP for the quorum + prover requests. Injectable for
    /// offline tests.
    public var checkpointFetcher: MyotisCheckpointFetcher = MyotisURLSessionFetcher()

    /// Engine handles by chain ID. Int64 ids from `myotis_create*`
    /// (>= 1); the engine owns the underlying state.
    private var handles: [UInt64: Int64] = [:]
    private var networks: [UInt64: MyotisNetwork] = [:]
    private var store: MyotisGenerationStore?
    private var pollTask: Task<Void, Never>?
    /// Bumped on every lifecycle transition so a slow start completing
    /// after `stop()` tears itself down (same pattern as `SwarmNode`).
    private var lifecycleGeneration = 0
    /// Per-chain recovery bookkeeping (not observable; the public
    /// `recovery` map is the projection).
    private var recoveryAttempt: [UInt64: Int] = [:]
    private var recoveryTask: [UInt64: Task<Void, Never>] = [:]
    private var retryTask: [UInt64: Task<Void, Never>] = [:]
    private var notReadySince: [UInt64: Date] = [:]
    private var lastReady: [UInt64: Bool] = [:]
    /// Recovery runs only while the app is in the foreground: the engine
    /// park is released by pause anyway, and the 90 s acquisition
    /// deadline exceeds what iOS grants a backgrounded app.
    private var isForeground = true
    /// Injectable clock for the pure decision paths.
    var now: () -> Date = { Date() }

    public init() {}

    public nonisolated static func defaultDataDir() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("myotis", isDirectory: true)
    }

    /// Verified reads can be served for `chainId` right now: engine
    /// ready AND no recovery in flight or blocked AND (for a verified
    /// generation) synced past the anchored checkpoint.
    public func isReady(chainId: UInt64) -> Bool {
        guard status == .running, handles[chainId] != nil, recovery[chainId] == nil,
              let chain = chainStatus[chainId]
        else { return false }
        return chain.ready && MyotisRecoveryPolicy.canFinish(status: chain, checkpoint: generations[chainId]?.checkpoint)
    }

    // MARK: - Lifecycle

    public func start(
        networks: [MyotisNetwork] = MyotisNetwork.allCases,
        dataDir: URL = MyotisNode.defaultDataDir()
    ) {
        guard handles.isEmpty, status != .starting else { return }
        lifecycleGeneration += 1
        let myGeneration = lifecycleGeneration
        status = .starting
        let store = MyotisGenerationStore(baseDir: dataDir)
        self.store = store
        append("starting myotis (\(networks.map(\.rawValue).joined(separator: ", ")))…")

        Task.detached(priority: .userInitiated) { [weak self] in
            let abi = myotis_init()
            guard abi == Self.expectedABI else {
                await MainActor.run {
                    self?.failStart(
                        "engine ABI \(abi) ≠ expected \(Self.expectedABI) — framework/wrapper skew",
                        generation: myGeneration
                    )
                }
                return
            }

            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            var boots: [(MyotisNetwork, Result<(Int64, MyotisGeneration), Boot.Failure>)] = []
            for network in networks {
                let generation: MyotisGeneration
                do {
                    generation = try store.loadOrCreate(network, nowMs: nowMs)
                    try store.checkNativeMarker(generation, network: network)
                } catch {
                    boots.append((network, .failure(.storage(MyotisGenerationStore.map(error)))))
                    continue
                }
                boots.append((network, Boot.launch(network: network, generation: generation)))
            }

            await MainActor.run {
                guard let self else {
                    for case (_, .success(let (handle, _))) in boots { myotis_stop(handle) }
                    return
                }
                guard self.lifecycleGeneration == myGeneration else {
                    for case (_, .success(let (handle, _))) in boots { myotis_stop(handle) }
                    self.append("start cancelled — discarding warmed-up engines")
                    return
                }
                var started = 0
                for (network, boot) in boots {
                    let chainId = network.chainId
                    self.networks[chainId] = network
                    switch boot {
                    case .success(let (handle, generation)):
                        self.handles[chainId] = handle
                        self.generations[chainId] = generation
                        started += 1
                        self.append("\(network.rawValue): \(generation.origin.rawValue) generation \(generation.id.prefix(8)) started")
                    case .failure(let failure):
                        self.generations[chainId] = failure.generation
                        self.append("start failure — \(network.rawValue): \(failure.description)")
                        self.recovery[chainId] = MyotisRecoveryState(
                            phase: .blocked, reason: failure.reason, attempt: 0,
                            canRetry: failure.reason.canRetry
                        )
                    }
                }
                guard started > 0 || !self.recovery.isEmpty else {
                    self.failStart("no engine started", generation: myGeneration)
                    return
                }
                self.status = .running
                self.append("engine running · ABI \(Self.expectedABI) · chains \(self.handles.keys.sorted())")
                self.startPolling()
            }
        }
    }

    public func stop() {
        lifecycleGeneration += 1
        let stopping = handles
        handles = [:]
        pollTask?.cancel()
        pollTask = nil
        for task in recoveryTask.values { task.cancel() }
        for task in retryTask.values { task.cancel() }
        recoveryTask = [:]
        retryTask = [:]
        recovery = [:]
        recoveryAttempt = [:]
        notReadySince = [:]
        for (chainId, wasReady) in lastReady where wasReady {
            onAvailabilityChange?(chainId, false)
        }
        lastReady = [:]
        chainStatus = [:]
        generations = [:]
        guard !stopping.isEmpty else {
            if status == .starting {
                status = .stopped
                append("stopped before startup completed")
            } else if status == .running {
                status = .stopped
                append("stopped")
            }
            return
        }
        status = .stopping
        append("shutting down…")
        Task.detached(priority: .userInitiated) { [weak self] in
            for handle in stopping.values { myotis_stop(handle) }
            await MainActor.run {
                guard let self else { return }
                self.status = .stopped
                self.append("stopped")
            }
        }
    }

    /// Idle-sleep on scenePhase `.background`: tears down the engines'
    /// networking but keeps warm state (snapshot + peer caches), so the
    /// foreground `resume()` is a warm restart (~10 s back to SYNCED)
    /// instead of a cold bootstrap. iOS will suspend us anyway; pausing
    /// first closes sockets cleanly instead of letting the OS reap them.
    /// In-flight checkpoint recovery is abandoned (it cannot finish in
    /// the background) and re-triggered by the next poll after resume.
    public func pause() {
        isForeground = false
        guard status == .running else { return }
        for (chainId, task) in recoveryTask {
            task.cancel()
            if let state = recovery[chainId], state.phase == .checking {
                recovery[chainId] = nil
                append("chain \(chainId): recovery paused for background")
            }
        }
        recoveryTask = [:]
        for (chainId, task) in retryTask {
            task.cancel()
            if recovery[chainId]?.phase == .waiting { recovery[chainId] = nil }
        }
        retryTask = [:]
        let paused = handles
        Task.detached(priority: .utility) { [weak self] in
            var count = 0
            for handle in paused.values where myotis_pause(handle) { count += 1 }
            let line = "paused \(count)/\(paused.count) engines for background"
            await MainActor.run { self?.append(line) }
        }
    }

    /// Warm restart on scenePhase `.active`. False returns from
    /// `myotis_resume` mean "wasn't paused" (short suspension) or a
    /// failed rebuild that stays PAUSED and is retried on next poll —
    /// both benign, so this is fire-and-forget like `SwarmNode.resume`.
    public func resume() {
        isForeground = true
        // Suspended time must not count toward the stall watchdog.
        notReadySince = [:]
        guard status == .running else { return }
        let resuming = handles
        Task.detached(priority: .userInitiated) { [weak self] in
            var count = 0
            for handle in resuming.values where myotis_resume(handle) { count += 1 }
            let line = count > 0 ? "resumed \(count)/\(resuming.count) engines" : "resume: engines were not paused"
            await MainActor.run { self?.append(line) }
        }
    }

    // MARK: - Recovery actions (Nodes UI)

    /// "Retry sync" while blocked. Storage/startup/stall reasons restart
    /// the same owned generation; everything else runs a fresh
    /// checkpoint recovery with the attempt counter reset.
    public func retryRecovery(chainId: UInt64) {
        guard status == .running, let state = recovery[chainId], state.phase == .blocked, state.canRetry else { return }
        if state.reason?.restartsOwnedState == true {
            restartOwnedState(chainId: chainId, repair: false)
        } else {
            recoverCheckpoint(chainId: chainId, resetAttempts: true)
        }
    }

    /// "Repair sync data": fresh bundled generation, old data preserved.
    public func repairSyncData(chainId: UInt64) {
        guard status == .running, recoveryTask[chainId] == nil else { return }
        restartOwnedState(chainId: chainId, repair: true)
    }

    // MARK: - Verified reads

    /// Verified `eth_call` over proof-served state. Blocking in the
    /// engine (up to ~90 s worst case) — runs detached and returns a
    /// decoded outcome. `.unavailable`/`.error` are the caller's cue to
    /// fall through to the next resolution tier.
    public func ethCall(
        chainId: UInt64,
        from: String = "",
        to: String,
        data: String,
        value: String = "0",
        block: String = "latest"
    ) async -> MyotisCallOutcome {
        guard let handle = runningHandle(chainId: chainId) else {
            return .unavailable(reason: "node not running for chain \(chainId)")
        }
        return await Task.detached(priority: .userInitiated) {
            Self.blockingEthCall(
                handle: handle, from: from, to: to, data: data, value: value, block: block
            )
        }.value
    }

    private nonisolated static func blockingEthCall(
        handle: Int64, from: String, to: String, data: String, value: String, block: String
    ) -> MyotisCallOutcome {
        let json: String? = from.withCString { fromPtr in
            to.withCString { toPtr in
                data.withCString { dataPtr in
                    value.withCString { valuePtr in
                        block.withCString { blockPtr in
                            takeString(myotis_eth_call_json(
                                handle, fromPtr, toPtr, dataPtr, valuePtr, blockPtr
                            ))
                        }
                    }
                }
            }
        }
        guard let json else { return .error("engine returned NULL") }
        return MyotisCallOutcome.decode(json)
    }

    // MARK: - Engine boot (off the main actor)

    /// One engine create+start, pure over its inputs so start and
    /// recovery share it.
    enum Boot {
        struct Failure: Error, CustomStringConvertible {
            var reason: MyotisRecoveryReason
            var generation: MyotisGeneration?
            var description: String

            static func storage(_ error: MyotisCheckpointError) -> Failure {
                Failure(reason: MyotisRecoveryReason(error), generation: nil, description: error.message)
            }
        }

        nonisolated static func launch(
            network: MyotisNetwork, generation: MyotisGeneration
        ) -> Result<(Int64, MyotisGeneration), Failure> {
            try? FileManager.default.createDirectory(at: generation.directory, withIntermediateDirectories: true)
            let handle: Int64 = network.rawValue.withCString { namePtr in
                generation.directory.path.withCString { dirPtr in
                    if let checkpoint = generation.checkpoint, generation.origin == .verified {
                        return checkpoint.root.withCString { rootPtr in
                            myotis_create_with_checkpoint(namePtr, dirPtr, rootPtr, checkpoint.slot)
                        }
                    }
                    return myotis_create(namePtr, dirPtr)
                }
            }
            if handle == MyotisNode.anchorMismatch {
                return .failure(Failure(
                    reason: .storage, generation: generation,
                    description: "engine refused the generation's anchor (ANCHOR_MISMATCH)"
                ))
            }
            guard handle >= 1 else {
                return .failure(Failure(
                    reason: .startup, generation: generation, description: "create failed (\(handle))"
                ))
            }
            guard myotis_start(handle) else {
                myotis_stop(handle)
                return .failure(Failure(
                    reason: .startup, generation: generation, description: "start returned false"
                ))
            }
            _ = myotis_set_served_block_window(handle, MyotisNode.servedBlockWindow)
            #if DEBUG
            // Smoke-test hook (simulator only): `FREEDOM_MYOTIS_WS_BOUND_PERIODS=1`
            // in the scheme environment lowers the weak-subjectivity bound on
            // BUNDLED generations so recovery can be exercised while the
            // embedded anchor is still in bound. Never applied to verified
            // generations, never persisted by the engine, not compiled into
            // release builds. Lowering (not raising) the bound can only park.
            if generation.origin == .bundled,
               let raw = ProcessInfo.processInfo.environment["FREEDOM_MYOTIS_WS_BOUND_PERIODS"],
               let periods = Int64(raw), periods > 0
            {
                _ = myotis_set_ws_bound_periods(handle, periods)
            }
            #endif
            return .success((handle, generation))
        }
    }

    // MARK: - Recovery state machine

    /// Desktop `recoverCheckpoint`: single-flight per chain. Acquire a
    /// quorum-and-proof-verified checkpoint, stop the parked engine,
    /// mint a verified generation, bootstrap from the checkpoint. The
    /// `restarting` phase clears only when the poll observes the engine
    /// SYNCED past the anchor (`canFinish`).
    private func recoverCheckpoint(chainId: UInt64, resetAttempts: Bool = false) {
        guard status == .running, recoveryTask[chainId] == nil, let network = networks[chainId],
              let store
        else { return }
        guard isForeground else {
            // Backgrounded: leave no stale state behind — the first poll
            // after resume observes STALE_ANCHOR and starts over.
            recovery[chainId] = nil
            return
        }
        retryTask[chainId]?.cancel()
        retryTask[chainId] = nil
        if resetAttempts { recoveryAttempt[chainId] = 0 }
        let startedAt = (resetAttempts || recovery[chainId]?.startedAt == nil) ? now() : recovery[chainId]?.startedAt
        guard let corroborator = checkpointCorroborator else {
            failRecovery(chainId: chainId, reason: .unsupported, retry: false, startedAt: startedAt)
            return
        }
        let attempt = (recoveryAttempt[chainId] ?? 0) + 1
        recoveryAttempt[chainId] = attempt
        recovery[chainId] = MyotisRecoveryState(phase: .checking, attempt: attempt, startedAt: startedAt)
        publishReadiness(chainId: chainId)
        append("chain \(chainId): stale anchor — acquiring verified checkpoint (attempt \(attempt))")
        let acquirer = MyotisCheckpointAcquirer(fetcher: checkpointFetcher, corroborator: corroborator)
        let token = lifecycleGeneration
        let task = Task { [weak self] in
            do {
                let record = try await acquirer.acquire(chainId: chainId)
                try Task.checkCancellation()
                guard let self, self.lifecycleGeneration == token else { return }
                self.recovery[chainId]?.phase = .restarting
                self.append("chain \(chainId): checkpoint verified · slot \(record.slot) · \(record.sources.count) sources — restarting")
                try await self.relaunch(chainId: chainId, network: network) {
                    try store.replace(network, checkpoint: record, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
                }
            } catch is CancellationError {
                return
            } catch {
                // A cancelled acquisition surfaces as `.unavailable` from the
                // deadline race; it must not schedule a retry after pause/stop.
                guard !Task.isCancelled, let self, self.lifecycleGeneration == token else { return }
                let code = MyotisCheckpointError.wrap(error)
                self.failRecovery(chainId: chainId, reason: MyotisRecoveryReason(code), retry: code.retryable, startedAt: startedAt)
            }
        }
        recoveryTask[chainId] = task
        Task { [weak self] in
            _ = await task.value
            await MainActor.run {
                guard let self, self.recoveryTask[chainId] == task else { return }
                self.recoveryTask[chainId] = nil
            }
        }
    }

    /// Desktop `restartOwnedState`: no new checkpoint — stop and relaunch
    /// the pointed-at generation (or, with `repair`, a fresh bundled
    /// one). If the anchor is really stale the engine parks again and
    /// the ordinary recovery runs with reset attempts.
    private func restartOwnedState(chainId: UInt64, repair: Bool) {
        guard status == .running, recoveryTask[chainId] == nil, let network = networks[chainId], let store
        else { return }
        retryTask[chainId]?.cancel()
        retryTask[chainId] = nil
        recoveryAttempt[chainId] = 0
        recovery[chainId] = MyotisRecoveryState(phase: .restarting, mode: .restart, attempt: 0, startedAt: now())
        publishReadiness(chainId: chainId)
        append("chain \(chainId): \(repair ? "repairing sync data" : "restarting node")")
        let token = lifecycleGeneration
        let task = Task { [weak self] in
            do {
                guard let self else { return }
                try await self.relaunch(chainId: chainId, network: network) {
                    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                    return repair ? try store.repair(network) : try store.loadOrCreate(network, nowMs: nowMs)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.lifecycleGeneration == token else { return }
                let code = MyotisCheckpointError.wrap(error)
                self.failRecovery(chainId: chainId, reason: MyotisRecoveryReason(code), retry: false, startedAt: self.now())
            }
        }
        recoveryTask[chainId] = task
        Task { [weak self] in
            _ = await task.value
            await MainActor.run {
                guard let self, self.recoveryTask[chainId] == task else { return }
                self.recoveryTask[chainId] = nil
            }
        }
    }

    /// Shared tail of both recovery paths: stop the current engine (the
    /// synchronous `myotis_stop` is the iOS "verified exit"), choose the
    /// generation, check its marker, launch. Throws checkpoint errors;
    /// a launch failure blocks with its own reason.
    private func relaunch(
        chainId: UInt64, network: MyotisNetwork,
        generation makeGeneration: @escaping @Sendable () throws -> MyotisGeneration
    ) async throws {
        guard let store else { throw MyotisCheckpointError.unsupported }
        let token = lifecycleGeneration
        if let previous = handles[chainId] {
            handles[chainId] = nil
            publishReadiness(chainId: chainId)
            await Task.detached(priority: .userInitiated) { myotis_stop(previous) }.value
            guard lifecycleGeneration == token else { throw CancellationError() }
        }
        try Task.checkCancellation()
        let boot: Result<(Int64, MyotisGeneration), Boot.Failure> = await Task.detached(priority: .userInitiated) {
            let generation: MyotisGeneration
            do {
                generation = try makeGeneration()
                try store.checkNativeMarker(generation, network: network)
            } catch {
                return .failure(.storage(MyotisGenerationStore.map(error)))
            }
            return Boot.launch(network: network, generation: generation)
        }.value
        guard lifecycleGeneration == token else {
            if case .success(let (handle, _)) = boot { myotis_stop(handle) }
            throw CancellationError()
        }
        switch boot {
        case .success(let (handle, generation)):
            handles[chainId] = handle
            generations[chainId] = generation
            chainStatus[chainId] = nil
            notReadySince[chainId] = nil
            append("chain \(chainId): \(generation.origin.rawValue) generation \(generation.id.prefix(8)) started")
        case .failure(let failure):
            if let generation = failure.generation { generations[chainId] = generation }
            append("chain \(chainId): relaunch failed — \(failure.description)")
            failRecovery(chainId: chainId, reason: failure.reason, retry: false, startedAt: recovery[chainId]?.startedAt)
        }
    }

    /// Desktop `failRecovery`: schedule the next automatic attempt on the
    /// ladder, or block for user action.
    private func failRecovery(chainId: UInt64, reason: MyotisRecoveryReason, retry: Bool, startedAt: Date?) {
        guard status == .running else { return }
        retryTask[chainId]?.cancel()
        retryTask[chainId] = nil
        let attempt = recoveryAttempt[chainId] ?? 0
        let delay = retry ? MyotisRecoveryPolicy.retryDelay(afterAttempt: attempt) : nil
        recovery[chainId] = MyotisRecoveryState(
            phase: delay == nil ? .blocked : .waiting, reason: reason, attempt: attempt,
            nextRetryAt: delay.map { now().addingTimeInterval($0) }, canRetry: reason.canRetry,
            startedAt: delay == nil ? nil : startedAt
        )
        publishReadiness(chainId: chainId)
        append("chain \(chainId): recovery \(delay == nil ? "blocked" : "waiting") — \(reason.rawValue)")
        guard let delay else { return }
        let token = lifecycleGeneration
        retryTask[chainId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.lifecycleGeneration == token else { return }
            self.retryTask[chainId] = nil
            self.recoverCheckpoint(chainId: chainId)
        }
    }

    /// Desktop `observeSync`, run on every status poll.
    func observeSync(chainId: UInt64, status fresh: MyotisChainStatus) {
        guard status == .running else { return }
        let inFlight = recoveryTask[chainId] != nil
        let state = recovery[chainId]
        if fresh.isStaleAnchor {
            if state == nil, !inFlight {
                recoverCheckpoint(chainId: chainId)
            } else if state?.phase == .blocked, state?.reason == .stalled, !inFlight {
                recoverCheckpoint(chainId: chainId, resetAttempts: true)
            } else if state?.phase == .waiting, retryTask[chainId] == nil, !inFlight {
                // A retry that was dropped by a background pause: resume it.
                recoverCheckpoint(chainId: chainId)
            } else if state?.phase == .restarting, !inFlight {
                if state?.mode == .restart {
                    recovery[chainId] = nil
                    recoverCheckpoint(chainId: chainId, resetAttempts: true)
                } else {
                    failRecovery(chainId: chainId, reason: .stale, retry: true, startedAt: state?.startedAt)
                }
            }
            return
        }
        let checkpoint = generations[chainId]?.checkpoint
        if MyotisRecoveryPolicy.isAnchorMismatch(status: fresh, checkpoint: checkpoint) {
            failRecovery(chainId: chainId, reason: .mismatch, retry: false, startedAt: nil)
            return
        }
        let finished = MyotisRecoveryPolicy.canFinish(status: fresh, checkpoint: checkpoint)
        let ready = finished && fresh.ready
        if (finished && state?.phase == .restarting) || (ready && state?.reason == .stalled) {
            retryTask[chainId]?.cancel()
            retryTask[chainId] = nil
            recovery[chainId] = nil
            recoveryAttempt[chainId] = 0
            append("chain \(chainId): recovery complete — synced from the verified anchor")
        }
        if ready, recovery[chainId] == nil {
            notReadySince[chainId] = nil
        } else {
            let since = notReadySince[chainId] ?? now()
            notReadySince[chainId] = since
            let current = recovery[chainId]
            if !inFlight, isForeground, current == nil || current?.phase == .restarting,
               now().timeIntervalSince(since) >= MyotisRecoveryPolicy.stallSeconds
            {
                failRecovery(chainId: chainId, reason: .stalled, retry: false, startedAt: nil)
            }
        }
    }

    // MARK: - Internals

    private func failStart(_ message: String, generation: Int) {
        guard lifecycleGeneration == generation else { return }
        status = .failed
        append("start failed: \(message)")
    }

    /// Fire `onAvailabilityChange` when node-level readiness flips.
    private func publishReadiness(chainId: UInt64) {
        let ready = isReady(chainId: chainId)
        let was = lastReady[chainId] ?? false
        guard ready != was else { return }
        lastReady[chainId] = ready
        append("chain \(chainId) \(ready ? "ready — verified reads available" : "no longer ready")")
        onAvailabilityChange?(chainId, ready)
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self, self.status == .running else { break }
                let snapshot = self.handles
                let decoded: [UInt64: MyotisChainStatus] = await Task.detached {
                    var out: [UInt64: MyotisChainStatus] = [:]
                    for (chainId, handle) in snapshot {
                        if let json = Self.takeString(myotis_status_json(handle)) {
                            out[chainId] = MyotisChainStatus.decode(json)
                        }
                    }
                    return out
                }.value
                guard self.status == .running else { break }
                for (chainId, fresh) in decoded {
                    // A status read that raced a relaunch belongs to the
                    // old handle — drop it.
                    guard self.handles[chainId] == snapshot[chainId] else { continue }
                    let previous = self.chainStatus[chainId]
                    let wasStale = previous?.isStaleAnchor ?? false
                    self.chainStatus[chainId] = fresh
                    // Diagnose "synced but not serving" once per change of
                    // reason — this is what a Colibri takeover looks like.
                    let reason = fresh.notServingReason
                    if !reason.isEmpty, reason != previous?.notServingReason {
                        self.append("chain \(chainId): synced but not serving — \(reason)")
                    }
                    if fresh.isStaleAnchor, !wasStale {
                        self.append("chain \(chainId): STALE_ANCHOR — anchor period \(fresh.currentPeriod), wall \(fresh.targetPeriod), bound \(fresh.wsBoundPeriods)")
                    }
                    self.observeSync(chainId: chainId, status: fresh)
                    self.publishReadiness(chainId: chainId)
                }
                tick += 1
                if tick % 5 == 0 { self.drainEngineLogs() }
                try? await Task.sleep(nanoseconds: Self.pollIntervalSeconds * 1_000_000_000)
            }
        }
    }

    /// Pull buffered engine tracing lines into the ring log (15 s
    /// cadence via the poll loop, mirroring the desktop manager).
    private func drainEngineLogs() {
        Task.detached(priority: .utility) { [weak self] in
            guard let lines = Self.takeString(myotis_drain_logs(50)), !lines.isEmpty else { return }
            await MainActor.run {
                guard let self else { return }
                for line in lines.split(separator: "\n").suffix(10) {
                    self.append(String(line))
                }
            }
        }
    }

    /// Copy + free an engine-owned C string (`myotis_string_free`, never
    /// `free(3)`). Internal so the wallet-reads extension shares it.
    nonisolated static func takeString(_ ptr: UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr else { return nil }
        defer { myotis_string_free(ptr) }
        return String(cString: ptr)
    }

    /// The engine handle for a chain iff the node is running and the
    /// chain is not mid-recovery — the wallet-reads extension's gate.
    func runningHandle(chainId: UInt64) -> Int64? {
        guard status == .running, recovery[chainId] == nil else { return nil }
        return handles[chainId]
    }

    private func append(_ line: String) {
        nodeLog.info("\(line, privacy: .public)")
        let ts = Date().formatted(date: .omitted, time: .standard)
        log.append("\(ts)  \(line)")
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}
