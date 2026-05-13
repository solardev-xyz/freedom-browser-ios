import Foundation
import Observation

/// `IPFSNode` is now a thin Swift facade over `FreedomIpfsReader` (Rust
/// read-only IPFS reader). The public type names — `IPFSNode`,
/// `IPFSStatus`, `IPFSConfig`, `IPFSRoutingMode` — are preserved from
/// the previous Kubo-backed implementation to keep the iOS app's blast
/// radius small.
///
/// What is NOT preserved from the Kubo era:
/// - There is no Kubo PeerID. `peerID` exists as an empty
///   compile-compatibility property; never display it.
/// - `peerCount` is meaningless (no libp2p peer set on the reader); kept
///   only to keep call sites compiling. Prefer `diagnostics`.
/// - Writing/pinning is not implemented; `add(_:)` always throws.

public enum IPFSStatus: String, Sendable {
    case idle, starting, running, stopping, stopped, failed
}

public enum IPFSError: LocalizedError {
    case notRunning
    case startFailed(String)
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .notRunning: "IPFS node is not running"
        case .startFailed(let message): "IPFS node failed to start: \(message)"
        case .unsupported: "Operation is not supported by the read-only IPFS reader"
        }
    }
}

/// Routing mode strings are kept for source compatibility with the old
/// Kubo settings. Mapping to Rust:
/// - `autoclient` → `.auto` (delegated + light DHT fallback)
/// - `dht` / `dhtclient` → `.lightDht`
/// - `disabled` → start an offline/cache-only gateway (no online retrieval)
public enum IPFSRoutingMode: String, Sendable, CaseIterable {
    case dht         = "dht"
    case dhtclient   = "dhtclient"
    case autoclient  = "autoclient"
    /// "none" — no online retrieval. Avoid the bare `.none` Swift case
    /// name to keep this from colliding with `Optional.none`.
    case disabled    = "none"
}

public struct IPFSConfig: Sendable {
    public var dataDir: URL
    /// Loopback host. Rust gateway only binds loopback addresses.
    public var gatewayHost: String
    /// `0` (the new default) means an ephemeral port — read the actual
    /// port back from `IPFSNode.gatewayURL` after start.
    public var gatewayPort: Int
    /// When true, scales request/provider budgets down for mobile.
    public var lowPower: Bool
    public var routingMode: IPFSRoutingMode
    /// When true, do not start the online retrieval gateway — only the
    /// local cache is served. Equivalent to `.disabled` routing.
    public var offline: Bool
    /// Block-store cache budget. `0` lets Rust use its built-in default.
    public var maxCacheBytes: UInt64
    /// Optional delegated-router endpoints. Empty uses the Rust default.
    public var delegatedRouters: [String]

    public init(
        dataDir: URL,
        gatewayHost: String = "127.0.0.1",
        gatewayPort: Int = 0,
        lowPower: Bool = false,
        routingMode: IPFSRoutingMode = .autoclient,
        offline: Bool = false,
        maxCacheBytes: UInt64 = 256 * 1024 * 1024,
        delegatedRouters: [String] = []
    ) {
        self.dataDir = dataDir
        self.gatewayHost = gatewayHost
        self.gatewayPort = gatewayPort
        self.lowPower = lowPower
        self.routingMode = routingMode
        self.offline = offline
        self.maxCacheBytes = maxCacheBytes
        self.delegatedRouters = delegatedRouters
    }

    public var gatewayAddr: String { "\(gatewayHost):\(gatewayPort)" }

    /// Translate the legacy routing-mode setting + offline flag into the
    /// shape the Rust reader expects.
    public var rustRoutingMode: FreedomIpfsRoutingMode {
        if offline { return .offline }
        switch routingMode {
        case .autoclient: return .auto
        case .dht, .dhtclient: return .lightDht
        case .disabled: return .offline
        }
    }

    /// Request-concurrency budget shaped by the `lowPower` flag. The
    /// freedom-ipfs latency-polish branch's mobile-web harness
    /// validates 8 as the performant default — anything below 4
    /// produces "Service Unavailable — gateway busy" 503s on real
    /// web pages, which fan out 10-20 parallel subresource requests
    /// at once. `lowPower` here is a "tighter mobile budget", not
    /// "starve the gateway."
    public var maxConcurrentRequests: Int { lowPower ? 4 : 8 }
    /// DHT budgets are kept identical across modes for now — the
    /// latency-polish profile uses 4 providers / 10s timeout
    /// regardless of the request-concurrency budget. The handoff
    /// flagged these as the measured performant numbers.
    public var dhtMaxProviders: Int { 4 }
    public var dhtQueryTimeoutSeconds: UInt64 { 10 }

}

@MainActor
@Observable
public final class IPFSNode {
    public private(set) var status: IPFSStatus = .idle
    /// Compile-compatibility shim — the Rust reader has no libp2p peer
    /// set. UI should hide this.
    public private(set) var peerCount: Int = 0
    /// Compile-compatibility shim — the Rust reader has no Kubo PeerID.
    /// Always empty. Never surface this in the UI.
    public let peerID: String = ""
    public private(set) var gatewayURL: URL?
    public private(set) var log: [String] = []
    public private(set) var activeRoutingMode: IPFSRoutingMode = .autoclient
    public private(set) var activeLowPower: Bool = true
    /// Latest snapshot from the polling loop. `nil` until first read.
    public private(set) var diagnostics: FreedomIpfsDiagnostics?
    /// Latest decoded progress snapshot from the Rust gateway's
    /// `progress_snapshot_json` API. `nil` while the node is
    /// stopped or before the first poll completes. The polling loop
    /// self-regulates: it ticks at ~300ms when there are active
    /// targets, ~1s when idle. See `IpfsProgressSnapshot` and
    /// `freedom-ipfs/docs/mobile-progress-api.md`.
    public private(set) var progressSnapshot: IpfsProgressSnapshot?

    private var reader: FreedomIpfsReader?
    private var nativeDispatcher: NativeGatewayDispatcher?
    private var pollTask: Task<Void, Never>?
    private var progressPollTask: Task<Void, Never>?
    private var activeConfig: IPFSConfig?
    /// Bumped on every state transition that should invalidate any
    /// in-flight `start` / `restart` detached task. After the slow Rust
    /// call returns, the resumption checks the captured generation
    /// against this counter — a mismatch means `stop()` (or another
    /// `start`/`restart`) ran while we were waiting, and the freshly
    /// configured reader is torn down instead of being published.
    private var lifecycleGeneration: Int = 0
    /// Monotonic counter for per-gateway-request correlation IDs.
    /// Stamped onto outgoing `X-Freedom-Request-ID` headers from the
    /// scheme handler so the Rust gateway groups subresources under
    /// their parent navigation in the progress snapshot. Shared
    /// across all tabs because Rust uses these as `target_id` in a
    /// single global event log. Main-actor isolated; the increment
    /// is safe because `IPFSNode` is `@MainActor` and every caller
    /// runs on main.
    private var requestIDCounter: UInt64 = 0

    public init() {}

    public static func defaultDataDir() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("freedom-ipfs", isDirectory: true)
    }

    public func start(_ config: IPFSConfig) {
        guard reader == nil else { return }
        lifecycleGeneration += 1
        let myGeneration = lifecycleGeneration
        activeRoutingMode = config.routingMode
        activeLowPower = config.lowPower
        activeConfig = config
        status = .starting
        append("starting freedom-ipfs (\(config.routingMode.rawValue), \(config.lowPower ? "lowpower" : "default"))…")

        try? FileManager.default.createDirectory(at: config.dataDir, withIntermediateDirectories: true)
        append("dataDir: \(config.dataDir.path)")

        let dataDir = config.dataDir
        let cacheBytes = config.maxCacheBytes
        let address = config.gatewayAddr
        let routingMode = config.rustRoutingMode
        let maxConcurrent = config.maxConcurrentRequests
        let dhtTimeout = config.dhtQueryTimeoutSeconds
        let dhtMax = config.dhtMaxProviders
        let routers = config.delegatedRouters

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let reader = try FreedomIpfsReader(
                    dataDirectory: dataDir,
                    maxCacheBytes: cacheBytes
                )
                try reader.startOnlineGateway(
                    address: address,
                    delegatedRouters: routers,
                    routingMode: routingMode,
                    maxConcurrentRequests: maxConcurrent,
                    dhtQueryTimeoutSeconds: dhtTimeout,
                    dhtMaxProviders: dhtMax
                )
                let resolvedURL = reader.gatewayURL
                let snapshot = reader.diagnostics
                await MainActor.run {
                    guard let self else {
                        // Owning IPFSNode was released — tear down the
                        // freshly-built reader so we don't leak a live
                        // gateway.
                        _ = reader.stopGateway()
                        return
                    }
                    guard self.lifecycleGeneration == myGeneration else {
                        // `stop()` or another `start`/`restart` ran
                        // while the gateway was warming up. Discard
                        // this reader instead of publishing it.
                        _ = reader.stopGateway()
                        self.append("start cancelled — discarding warmed-up gateway")
                        return
                    }
                    self.reader = reader
                    let dispatcher = NativeGatewayDispatcher(eventSource: reader)
                    dispatcher.start()
                    self.nativeDispatcher = dispatcher
                    self.gatewayURL = resolvedURL
                    self.diagnostics = snapshot
                    self.status = .running
                    let urlString = resolvedURL?.absoluteString ?? "(no gateway)"
                    self.append("node running · gateway \(urlString)")
                    self.startPolling()
                }
            } catch {
                await MainActor.run {
                    guard let self, self.lifecycleGeneration == myGeneration else { return }
                    self.status = .failed
                    self.append("start failed: \(error.localizedDescription)")
                }
            }
        }
    }

    public func restart(_ config: IPFSConfig) async {
        // If the reader is alive, reuse its handle by calling
        // `restartOnlineGateway` — avoids tearing down the cache for a
        // routing-mode flip. The Rust reader treats `.offline` mode as
        // a valid restart target, so this also covers the
        // disabled / cache-only flow.
        if let reader {
            lifecycleGeneration += 1
            let myGeneration = lifecycleGeneration
            activeRoutingMode = config.routingMode
            activeLowPower = config.lowPower
            activeConfig = config
            status = .starting
            append("restarting gateway (\(config.routingMode.rawValue), \(config.lowPower ? "lowpower" : "default"))…")
            let address = config.gatewayAddr
            let routingMode = config.rustRoutingMode
            let maxConcurrent = config.maxConcurrentRequests
            let dhtTimeout = config.dhtQueryTimeoutSeconds
            let dhtMax = config.dhtMaxProviders
            let routers = config.delegatedRouters
            do {
                try await Task.detached(priority: .userInitiated) {
                    try reader.restartOnlineGateway(
                        address: address,
                        delegatedRouters: routers,
                        routingMode: routingMode,
                        maxConcurrentRequests: maxConcurrent,
                        dhtQueryTimeoutSeconds: dhtTimeout,
                        dhtMaxProviders: dhtMax
                    )
                }.value
                // The Rust restart held us across an `await`. If
                // `stop()` (or another lifecycle action) ran during
                // that window, the reader we restarted has already
                // been torn down on the main side — drop the result
                // instead of re-publishing stale state.
                guard lifecycleGeneration == myGeneration else { return }
                gatewayURL = reader.gatewayURL
                diagnostics = reader.diagnostics
                status = .running
                let urlString = gatewayURL?.absoluteString ?? "(no gateway)"
                append("node running · gateway \(urlString)")
                return
            } catch {
                guard lifecycleGeneration == myGeneration else { return }
                status = .failed
                append("restart failed: \(error.localizedDescription)")
                return
            }
        }
        // Otherwise start fresh — covers idle/stopped/failed.
        start(config)
    }

    public func stop() {
        // Bumping the generation invalidates any in-flight `start` /
        // `restart` task. Without this, a slow startup that completes
        // after the user toggles off would silently re-publish itself.
        lifecycleGeneration += 1
        guard let reader else {
            // No reader was published yet, but a startup may still be
            // racing in the background — its post-await guard will
            // see the gen mismatch and tear itself down. Settle the
            // visible state here.
            if status == .starting {
                status = .stopped
                append("stopped before startup completed")
            }
            return
        }
        status = .stopping
        append("shutting down…")
        pollTask?.cancel()
        pollTask = nil
        progressPollTask?.cancel()
        progressPollTask = nil
        let captured = reader
        let capturedDispatcher = nativeDispatcher
        nativeDispatcher = nil
        self.reader = nil
        gatewayURL = nil
        // Clear synchronously alongside `self.reader` — otherwise the
        // detached `stopGateway()` hop below leaves a window where the
        // UI sees the last in-flight progress targets while the node
        // is reported as stopping.
        progressSnapshot = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            capturedDispatcher?.stop()
            _ = captured.stopGateway()
            await MainActor.run {
                guard let self else { return }
                self.status = .stopped
                self.peerCount = 0
                self.diagnostics = nil
                self.append("stopped")
            }
        }
    }

    /// Writing to IPFS is not part of the Rust reader's surface area.
    /// Always throws — present for source-level compatibility.
    public func add(_ data: Data) async throws -> String {
        _ = data
        throw IPFSError.unsupported
    }

    /// Translate an `ipfs://` / `ipns://` URL or a `/ipfs/...` /
    /// `/ipns/...` gateway-style path into a localhost gateway URL bound
    /// to whatever ephemeral port the Rust reader is listening on.
    public func localGatewayURL(for address: String) -> URL? {
        reader?.localGatewayURL(for: address)
    }

    /// Fire-and-forget preload. `0` if the reader isn't running. The
    /// returned task ID can be passed to `cancelPreload(_:)`.
    @discardableResult
    public func preload(path: String) -> UInt64 {
        reader?.preload(path: path) ?? 0
    }

    @discardableResult
    public func cancelPreload(taskID: UInt64) -> Bool {
        reader?.cancelPreload(taskID: taskID) ?? false
    }

    // MARK: - Lifecycle hooks (called by the app)

    public func enterBackground() {
        _ = reader?.enterBackground()
    }

    public func enterForeground() {
        _ = reader?.enterForeground()
    }

    public func handleLowMemory(maxCacheBytes: UInt64 = 0) {
        _ = reader?.handleLowMemory(maxCacheBytes: maxCacheBytes)
    }

    public func handleNetworkChange() {
        _ = reader?.handleNetworkChange()
    }

    // MARK: - Debug actions

    /// Clears provider metadata and bad-provider markers in the Rust
    /// reader. Verified cached blocks are preserved. Safe to call
    /// while the gateway is running. Internally a `handleNetworkChange`
    /// — the reader treats it as a routing-state reset. Surfaced under
    /// a clearer name for the debug UI.
    public func resetRoutingState() {
        _ = reader?.handleNetworkChange()
    }

    /// Removes all cached IPFS blocks. Future loads will be cold.
    /// Safe to call while the gateway is running. Returns `false` if
    /// the reader isn't up.
    @discardableResult
    public func clearCache() -> Bool {
        let ok = reader?.clearCache() ?? false
        diagnostics = reader?.diagnostics
        return ok
    }

    /// Clears the Rust progress event log + active-target tracking.
    /// Safe to call any time. Resets the local `progressSnapshot` to
    /// `.empty` immediately so the UI doesn't briefly hold stale
    /// counts before the next poll cycle.
    @discardableResult
    public func clearProgress() -> Bool {
        let ok = reader?.clearProgress() ?? false
        progressSnapshot = .empty
        return ok
    }

    /// Raw JSON snapshot string for debug logging or pass-through to
    /// places that don't want a typed model.
    public var progressSnapshotJSON: String? {
        reader?.progressSnapshotJSON
    }

    /// Fresh sample bypassing the 5-second cached `diagnostics`
    /// property. Use when before/after deltas need to be tighter
    /// than the poll interval (e.g. test harnesses around a single
    /// short page load).
    public func snapshotDiagnostics() -> FreedomIpfsDiagnostics? {
        reader?.diagnostics
    }

    /// Fresh decoded sample bypassing the 300ms-1s cached
    /// `progressSnapshot` property. Same use case as
    /// `snapshotDiagnostics()`.
    public func snapshotProgress() -> IpfsProgressSnapshot? {
        guard let json = reader?.progressSnapshotJSON else { return nil }
        return try? IpfsProgressSnapshot.decoder.decode(
            IpfsProgressSnapshot.self,
            from: Data(json.utf8)
        )
    }

    /// Raw native FFI transport counters JSON. Returns `nil` when the
    /// node isn't running. Shape per Rust's
    /// `NativeGatewayStatsSnapshot` (`active_native_handles`,
    /// `total_started/completed/failed/cancelled/freed`, `bytes_read`,
    /// `events_enqueued/delivered/coalesced`, queue depth fields,
    /// `last_native_error_code/_message`). Captured as a raw string so
    /// the harness can stash it without locking us into a Swift type
    /// before the Rust shape stabilises.
    public func snapshotNativeGatewayStatsJSON() -> String? {
        reader?.nativeGatewayStatsJSON
    }

    /// Allocate a fresh correlation ID for an outgoing gateway
    /// request. The scheme handler stamps this onto
    /// `X-Freedom-Request-ID`; the Rust gateway uses it as the
    /// target id, which is the join key for parent / subresource
    /// grouping in the progress snapshot.
    public func nextGatewayRequestID() -> UInt64 {
        requestIDCounter += 1
        return requestIDCounter
    }

    // MARK: - Native gateway request FFI (experimental)
    // Throws IPFSError.notRunning when the node is stopped. The sink
    // is registered with the node's shared event dispatcher before
    // this function returns, so an event emitted between start and
    // register cannot land before the sink is ready. See
    // freedom-ipfs/docs/native-gateway-api.md.

    public func startNativeGatewayRequest<Sink: NativeRequestSink>(
        json: String,
        makeSink: (NativeGatewayHandle) -> Sink
    ) throws -> (handle: NativeGatewayHandle, sink: Sink) {
        guard let reader, let dispatcher = nativeDispatcher else { throw IPFSError.notRunning }
        let id = try reader.startNativeGatewayRequest(json: json)
        let handle = NativeGatewayHandle(id: id, reader: reader)
        let sink = makeSink(handle)
        dispatcher.register(handleID: id, sink: sink)
        return (handle, sink)
    }

    /// Tombstones the handle in the dispatcher — future events are
    /// dropped until Rust emits `.handleFreed`. Call from scheme-handler
    /// stop / cancel paths after `handle.cancel()`.
    public func unregisterNativeGatewaySink(handleID: UInt64) {
        nativeDispatcher?.unregister(handleID: handleID)
    }

    // MARK: - Internals

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let reader = self.reader else { break }
                let snapshot = reader.diagnostics
                self.diagnostics = snapshot
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        progressPollTask = Task { [weak self] in
            // 300ms while a target is in flight, 1s when idle.
            let fastSleep: UInt64 =   300_000_000
            let slowSleep: UInt64 = 1_000_000_000
            while !Task.isCancelled {
                guard let self, let reader = self.reader else { break }
                let json = reader.progressSnapshotJSON
                let decoded = try? IpfsProgressSnapshot.decoder.decode(
                    IpfsProgressSnapshot.self,
                    from: Data(json.utf8)
                )
                // Equality guard avoids burning a SwiftUI invalidation
                // every tick during long idles where nothing changes.
                if let decoded, decoded != self.progressSnapshot {
                    self.progressSnapshot = decoded
                }
                let activeCount = decoded?.active.count ?? 0
                try? await Task.sleep(nanoseconds: activeCount > 0 ? fastSleep : slowSleep)
            }
        }
    }

    private func append(_ line: String) {
        let ts = Date().formatted(date: .omitted, time: .standard)
        log.append("\(ts)  \(line)")
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}

/// Protocol seam for `NativeGatewayHandle` so the scheme handler's
/// `NativePending` can be unit-tested against a fake handle without a
/// running Rust reader. Production conformance is the struct below.
public protocol NativeGatewayHandleProtocol: Sendable {
    var id: UInt64 { get }
    /// Block up to `timeoutMilliseconds` waiting for response metadata.
    /// Pass `0` for nonblocking semantics.
    func responseJSON(timeoutMilliseconds: UInt64) throws -> String
    /// Block up to `timeoutMilliseconds` waiting for body bytes,
    /// completion, cancellation, or failure. Pass `0` for nonblocking
    /// semantics. Buffer remains caller-owned.
    func read(
        into buffer: UnsafeMutableRawBufferPointer,
        timeoutMilliseconds: UInt64
    ) throws -> FreedomIpfsNativeGatewayReadResult
    @discardableResult func cancel() -> Bool
    @discardableResult func free() -> Bool
}

/// Handle for an in-flight native gateway request. Bundles the Rust
/// request id with a strong `FreedomIpfsReader` ref so the caller can
/// drive the FFI off the main actor without going through `IPFSNode`.
public struct NativeGatewayHandle: NativeGatewayHandleProtocol {
    public let id: UInt64
    private let reader: FreedomIpfsReader

    fileprivate init(id: UInt64, reader: FreedomIpfsReader) {
        self.id = id
        self.reader = reader
    }

    public func responseJSON(timeoutMilliseconds: UInt64) throws -> String {
        try reader.nativeGatewayResponseJSON(
            requestHandle: id,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    public func read(
        into buffer: UnsafeMutableRawBufferPointer,
        timeoutMilliseconds: UInt64
    ) throws -> FreedomIpfsNativeGatewayReadResult {
        try reader.readNativeGatewayRequest(
            id,
            into: buffer,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    @discardableResult
    public func cancel() -> Bool {
        reader.cancelNativeGatewayRequest(id)
    }

    @discardableResult
    public func free() -> Bool {
        reader.freeNativeGatewayRequest(id)
    }
}
