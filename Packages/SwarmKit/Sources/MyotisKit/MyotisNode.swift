import Foundation
import Observation
import FreedomMobile

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
/// verified reads can be served right now (see `MyotisChainStatus.ready`).
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

    /// Whether a verified read attempted now has a realistic chance of
    /// being answered. Beacon `SYNCED` alone is not enough: right after
    /// sync the EL side can still lack a snap peer, and every read fails
    /// with "state unavailable" / "no snap peer available" (observed in
    /// the Phase 0 spike). Gating on `snapPeers >= 1` skips the tier
    /// during that warm-up instead of burning a failed attempt per
    /// resolution.
    public var ready: Bool {
        running && !paused && beaconState == "SYNCED" && snapPeers >= 1
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
    /// The engine ABI this wrapper was written against (myotis v0.1.7).
    /// `start()` refuses to run against any other — a stale framework
    /// would otherwise fail confusingly deep inside a resolve.
    public static let expectedABI: Int32 = 22

    /// Live-set eth/69 served-block window. The engine default (32,
    /// ~16 KB per served request) suits a desktop; on a phone we serve
    /// the protocol minimum and keep the data budget for our own reads.
    public static let servedBlockWindow: Int32 = 1

    public private(set) var status: MyotisStatus = .idle
    /// Per-network engine status, keyed by chain ID (1, 100).
    public private(set) var chainStatus: [UInt64: MyotisChainStatus] = [:]
    public private(set) var log: [String] = []

    /// Fired on every per-chain availability flip (`ready` transitioned).
    /// The app hooks resolver-cache sweeps here so a freshly-ready node
    /// takes over immediately instead of waiting out cached TTLs.
    public var onAvailabilityChange: ((_ chainId: UInt64, _ ready: Bool) -> Void)?

    /// Engine handles by chain ID. Int64 ids from `myotis_create`
    /// (>= 1); the engine owns the underlying state.
    private var handles: [UInt64: Int64] = [:]
    private var pollTask: Task<Void, Never>?
    /// Bumped on every lifecycle transition so a slow start completing
    /// after `stop()` tears itself down (same pattern as `SwarmNode`).
    private var lifecycleGeneration = 0

    public init() {}

    public nonisolated static func defaultDataDir() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("myotis", isDirectory: true)
    }

    public func isReady(chainId: UInt64) -> Bool {
        chainStatus[chainId]?.ready ?? false
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

            var started: [UInt64: Int64] = [:]
            var failures: [String] = []
            for network in networks {
                let dir = dataDir.appendingPathComponent(network.rawValue, isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let handle = network.rawValue.withCString { namePtr in
                    dir.path.withCString { dirPtr in
                        myotis_create(namePtr, dirPtr)
                    }
                }
                guard handle >= 1 else {
                    failures.append("\(network.rawValue): create failed (\(handle))")
                    continue
                }
                guard myotis_start(handle) else {
                    failures.append("\(network.rawValue): start returned false")
                    myotis_stop(handle)
                    continue
                }
                _ = myotis_set_served_block_window(handle, Self.servedBlockWindow)
                started[network.chainId] = handle
            }

            await MainActor.run {
                guard let self else {
                    for handle in started.values { myotis_stop(handle) }
                    return
                }
                guard self.lifecycleGeneration == myGeneration else {
                    for handle in started.values { myotis_stop(handle) }
                    self.append("start cancelled — discarding warmed-up engines")
                    return
                }
                for line in failures { self.append("start failure — \(line)") }
                guard !started.isEmpty else {
                    self.failStart(failures.joined(separator: "; "), generation: myGeneration)
                    return
                }
                self.handles = started
                self.status = .running
                self.append("engine running · ABI \(Self.expectedABI) · chains \(started.keys.sorted())")
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
        for (chainId, status) in chainStatus where status.ready {
            onAvailabilityChange?(chainId, false)
        }
        chainStatus = [:]
        guard !stopping.isEmpty else {
            if status == .starting {
                status = .stopped
                append("stopped before startup completed")
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
    public func pause() {
        guard status == .running else { return }
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
        guard status == .running else { return }
        let resuming = handles
        Task.detached(priority: .userInitiated) { [weak self] in
            var count = 0
            for handle in resuming.values where myotis_resume(handle) { count += 1 }
            let line = count > 0 ? "resumed \(count)/\(resuming.count) engines" : "resume: engines were not paused"
            await MainActor.run { self?.append(line) }
        }
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
        guard status == .running, let handle = handles[chainId] else {
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

    // MARK: - Internals

    private func failStart(_ message: String, generation: Int) {
        guard lifecycleGeneration == generation else { return }
        status = .failed
        append("start failed: \(message)")
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
                for (chainId, fresh) in decoded {
                    let wasReady = self.chainStatus[chainId]?.ready ?? false
                    self.chainStatus[chainId] = fresh
                    if fresh.ready != wasReady {
                        self.append(
                            "chain \(chainId) \(fresh.ready ? "ready — verified reads available" : "no longer ready")"
                        )
                        self.onAvailabilityChange?(chainId, fresh.ready)
                    }
                }
                tick += 1
                if tick % 3 == 0 { self.drainEngineLogs() }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
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

    /// The engine handle for a chain iff the node is running — the
    /// wallet-reads extension's gate.
    func runningHandle(chainId: UInt64) -> Int64? {
        guard status == .running else { return nil }
        return handles[chainId]
    }

    private func append(_ line: String) {
        let ts = Date().formatted(date: .omitted, time: .standard)
        log.append("\(ts)  \(line)")
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}
