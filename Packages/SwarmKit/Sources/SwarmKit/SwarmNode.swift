import Foundation
import Observation
import FreedomMobile

/// `SwarmNode` is now a thin Swift facade over the Rust **Ant** node
/// (`ant-ffi`), replacing the previous gomobile bee-lite backing. The
/// public type names — `SwarmNode`, `SwarmStatus`, `SwarmConfig`,
/// `SwarmFile` — are preserved so the app's blast radius stays small.
///
/// Ant boots its own libp2p Swarm node (`ant_init`) and then serves a
/// **bee-compatible HTTP gateway in-process** on `127.0.0.1:1633`
/// (`ant_start_gateway`) — so the app's existing bee-HTTP layer
/// (`BeeAPIClient`, `BzzSchemeHandler`, feeds, stamps) talks to it
/// unchanged. There is no separate `antd` process.
///
/// What is NOT preserved from the bee era:
/// - `SwarmConfig.password` / `.bootnodes` / `.mainnet` / `.networkID`
///   are kept for source compatibility but ignored: Ant manages its own
///   persistent identity (`identity.json`) and mainnet bootstrap. Only
///   `rpcEndpoint` is consulted, as the light-vs-ultra-light signal.
public enum SwarmStatus: String, Sendable {
    case idle, starting, running, stopping, stopped, failed
}

public struct SwarmFile: Sendable {
    public let name: String
    public let data: Data
}

public enum SwarmError: LocalizedError {
    case notRunning
    case notFound
    case startFailed(String)
    case identitySeedFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning: "Swarm node is not running"
        case .notFound: "content not found on Swarm"
        case .startFailed(let message): "Swarm node failed to start: \(message)"
        case .identitySeedFailed(let message): "Couldn't seed Swarm identity: \(message)"
        }
    }
}

public struct SwarmConfig: Sendable {
    public var dataDir: URL
    public var password: String
    public var rpcEndpoint: String?       // nil → no chain access (Freedom always passes one)
    public var bootnodes: String          // pipe-delimited list of multiaddrs
    public var mainnet: Bool
    public var networkID: Int64

    // Retained for source compatibility with the bee-era config builder.
    // Ant uses its own built-in mainnet bootstrap + `peers.json`, so
    // these are no longer consulted by `start(_:)`.
    public static let defaultBootnodes: [String] = [
        "/ip4/135.181.84.53/tcp/1634/p2p/QmTxX73q8dDiVbmXU7GqMNwG3gWmjSFECuMoCsTW4xp6CK",
        "/ip4/139.84.229.70/tcp/1634/p2p/QmRa6rSrUWJ7s68MNmV94bo2KAa9pYcp6YbFLMHZ3r7n2M",
        "/ip4/159.223.6.181/tcp/1634/p2p/QmP9b7MxjyEfrJrch5jUThmuFaGzvUPpWEJewCpx5Ln6i8",
        "/ip4/170.64.184.25/tcp/1634/p2p/Qmeh2e7U2FWrSooyrjWjnNKGceJWbRxLLx8Ppy5CimzsGH",
        "/ip4/172.104.43.205/tcp/1634/p2p/QmeovveLJmgyfjiA9mJnvFTawHyisuJMCYicJffdWdxNmr",
    ]

    public init(
        dataDir: URL,
        password: String,
        rpcEndpoint: String? = nil,
        bootnodes: String = Self.defaultBootnodes.joined(separator: "|"),
        mainnet: Bool = true,
        networkID: Int64 = 1
    ) {
        self.dataDir = dataDir
        self.password = password
        self.rpcEndpoint = rpcEndpoint
        self.bootnodes = bootnodes
        self.mainnet = mainnet
        self.networkID = networkID
    }
}

/// The disk chunk cache's figures (`ant_cache_status`, ant v0.5.60).
/// Pinned chunks sit outside the cap and are never evicted or cleared.
public struct SwarmCacheStatus: Equatable, Sendable, Decodable {
    /// False when `chunks.sqlite` couldn't be opened (every figure is 0).
    public let diskEnabled: Bool
    /// Unpinned cached chunks, counted against `capacityBytes`.
    public let usedBytes: UInt64
    public let capacityBytes: UInt64
    public let pinnedBytes: UInt64
    /// `chunks.sqlite` plus its `-wal` / `-shm` on disk.
    public let fileBytes: UInt64

    enum CodingKeys: String, CodingKey {
        case diskEnabled = "disk_enabled"
        case usedBytes = "used_bytes"
        case capacityBytes = "capacity_bytes"
        case pinnedBytes = "pinned_bytes"
        case fileBytes = "file_bytes"
    }

    public init(diskEnabled: Bool, usedBytes: UInt64, capacityBytes: UInt64, pinnedBytes: UInt64, fileBytes: UInt64) {
        self.diskEnabled = diskEnabled
        self.usedBytes = usedBytes
        self.capacityBytes = capacityBytes
        self.pinnedBytes = pinnedBytes
        self.fileBytes = fileBytes
    }
}

/// What `ant_cache_clear` removed.
public struct SwarmCacheClearResult: Equatable, Sendable, Decodable {
    public let freedBytes: UInt64
    public let fileBytesBefore: UInt64
    public let fileBytesAfter: UInt64
    public let status: SwarmCacheStatus

    enum CodingKeys: String, CodingKey {
        case freedBytes = "freed_bytes"
        case fileBytesBefore = "file_bytes_before"
        case fileBytesAfter = "file_bytes_after"
        case status
    }
}

/// The node's rediscovery of the wallet's postage batches and chequebook
/// (`/health.walletScan`, ant v0.5.59 #142). Absent while no background
/// rediscovery runs.
public struct WalletScan: Equatable, Sendable, Decodable {
    /// `pending`, `scanning`, `retrying`, `confirming` or `done`; an
    /// unknown state counts as finished.
    public let state: String
    public let from: Int?
    public let scannedThrough: Int?
    public let head: Int?
    /// Why the last attempt failed (URLs replaced by `<url>`). For the
    /// log, not for display.
    public let error: String?

    public init(state: String, from: Int? = nil, scannedThrough: Int? = nil, head: Int? = nil, error: String? = nil) {
        self.state = state
        self.from = from
        self.scannedThrough = scannedThrough
        self.head = head
        self.error = error
    }

    /// Still looking: the batches it will find are not registered yet, so
    /// the app must not offer to buy storage. `confirming` is not looking
    /// — its batches are registered, only completeness is being confirmed.
    public var isLooking: Bool { ["pending", "scanning", "retrying"].contains(state) }
    public var isRetrying: Bool { state == "retrying" }

    /// 0…1 while scanning with known bounds.
    public var progress: Double? {
        guard let from, let head, let scannedThrough, head > from else { return nil }
        return min(1, max(0, Double(scannedThrough - from) / Double(head - from)))
    }
}

@MainActor
@Observable
public final class SwarmNode {
    public private(set) var status: SwarmStatus = .idle
    public private(set) var peerCount: Int = 0
    public private(set) var walletAddress: String = ""
    public private(set) var log: [String] = []
    /// From `/health`, refreshed with the peer count; nil when no
    /// rediscovery runs.
    public private(set) var walletScan: WalletScan?

    /// Loopback authority the in-process bee gateway binds. Fixed to
    /// bee's default port so the app's `BeeAPIClient` / `BzzSchemeHandler`
    /// reach it with no base-URL change.
    public static let gatewayAuthority = "127.0.0.1:1633"

    /// Opaque `AntHandle*` from `ant_init`, freed by `ant_shutdown`.
    private var node: OpaquePointer?
    private var pollTask: Task<Void, Never>?
    /// Bumped on every lifecycle transition so a slow `ant_init` /
    /// `ant_start_gateway` that completes after `stop()` tears itself
    /// down instead of publishing a live node nobody can stop.
    private var lifecycleGeneration = 0
    /// Last config handed to `start(_:)`, retained so `resume()` can
    /// rebind the gateway with the same light-mode / RPC settings after a
    /// suspension reaped its loopback listener.
    private var lastConfig: SwarmConfig?

    /// Host-provided Gnosis JSON-RPC transport (ant's `ant_set_chain_transport`,
    /// issue #77): every chain request the node makes — `eth_call`,
    /// `eth_getLogs`, `eth_sendRawTransaction`, … — is handed to this
    /// closure as a complete JSON-RPC request body and expects a JSON-RPC
    /// response body back, or `nil` for "can't serve" (ant then falls
    /// back to `SwarmConfig.rpcEndpoint`). Called on ant's blocking pool,
    /// possibly concurrently, never on the main thread; blocking inside
    /// it is expected. Set before `start(_:)` — the gateway captures its
    /// chain wiring at start.
    public var chainTransport: (@Sendable (String) -> String?)?
    /// The retained callback context for the installed transport, kept
    /// until `ant_shutdown` has drained every in-flight callback.
    private var chainTransportBox: Unmanaged<ChainTransportBox>?
    /// Gnosis RPC handed to the `ant_storage_*` calls as their fallback
    /// transport (the installed chain transport answers first). Needed
    /// in every mode: storage can be bought while the node still browses
    /// ultra-light.
    public var storageRPC: String = "https://rpc.gnosischain.com"
    /// Explicitly unverified source for a wallet scan span the chain
    /// transport can't serve in a few windows (a first scan, a long time
    /// offline): ant reads it once from here, reports
    /// `walletScan.state = confirming` and re-confirms it in the
    /// background through the transport (`ant_set_unverified_logs_rpc`,
    /// ant v0.5.59 #143). That one `eth_getLogs` goes to this URL
    /// directly, not through the transport. Set before `start(_:)`; nil
    /// leaves it unset.
    public var unverifiedLogsRPC: String?
    /// Bee's swap-enable: pay peers with SWAP cheques from the chequebook
    /// for downloads and uploads past the free tier (ant v0.5.57). ant
    /// defaults it on and does not persist it, so it is applied after
    /// every `ant_init`; `setSwapEnabled` changes it on a running node.
    public private(set) var swapEnabled: Bool = true
    /// The disk chunk cache's cap, handed to `ant_init_with_config` at
    /// every start (ant doesn't persist it). Nil leaves ant's default.
    /// `setCacheCapacity` changes it on a running node too.
    public var cacheCapacityBytes: UInt64?

    public enum StorageError: Swift.Error, LocalizedError {
        case notRunning
        /// ant's own message ("not enough xDAI: send 0.3 more", …).
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notRunning: "The Swarm node isn't running."
            case .failed(let message): message
            }
        }
    }

    public init() {}

    public nonisolated static func defaultDataDir() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("swarm", isDirectory: true)
    }

    /// Seed Ant's `identity.json` so the next `start(_:)` adopts
    /// `signingKey` (the user's vault-derived Swarm secp256k1 secret)
    /// instead of generating a random identity. Overwrites any existing
    /// file. Call while the node is stopped, before `start(_:)`.
    ///
    /// The overlay address Ant derives is
    /// `keccak256(ethAddress ‖ networkID_le ‖ overlay_nonce)`. We write a
    /// **32-zero `overlay_nonce`** to match desktop `antd`'s
    /// `keys/swarm.key` injection branch (which also uses a zero nonce) —
    /// the eth address (same `m/44'/60'/0'/0/1` key) and networkID (1)
    /// already match, so the overlay comes out **byte-identical** to
    /// desktop for the same wallet. `libp2p_keypair` is omitted so Ant
    /// derives it deterministically from the signing key.
    public nonisolated static func writeInjectedIdentity(
        signingKey: Data,
        dataDir: URL = SwarmNode.defaultDataDir()
    ) throws {
        guard signingKey.count == 32 else {
            throw SwarmError.identitySeedFailed(
                "signing key must be 32 bytes, got \(signingKey.count)"
            )
        }
        struct IdentityFile: Encodable {
            let signing_key: String
            let overlay_nonce: String
        }
        let identity = IdentityFile(
            signing_key: signingKey.map { String(format: "%02x", $0) }.joined(),
            overlay_nonce: String(repeating: "0", count: 64) // 32 zero bytes
        )
        do {
            try FileManager.default.createDirectory(
                at: dataDir, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(identity)
                .write(to: dataDir.appendingPathComponent("identity.json"))
        } catch let error as SwarmError {
            throw error
        } catch {
            throw SwarmError.identitySeedFailed(error.localizedDescription)
        }
    }

    /// Fetch a `/bzz/<ref>` document through the in-process gateway.
    /// Preserved for source compatibility; the app's content paths go
    /// through `BeeAPIClient` / `BzzSchemeHandler` directly.
    public func download(hash: String) async throws -> SwarmFile {
        guard node != nil else { throw SwarmError.notRunning }
        guard let url = URL(string: "http://\(Self.gatewayAuthority)/bzz/\(hash)") else {
            throw SwarmError.notFound
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SwarmError.notFound
        }
        return SwarmFile(name: hash, data: data)
    }

    public func start(_ config: SwarmConfig) {
        guard node == nil else { return }
        lastConfig = config
        lifecycleGeneration += 1
        let myGeneration = lifecycleGeneration
        let lightMode = config.rpcEndpoint != nil
        status = .starting
        append("starting ant node (\(lightMode ? "light" : "ultra-light"))…")

        try? FileManager.default.createDirectory(at: config.dataDir, withIntermediateDirectories: true)
        append("dataDir: \(config.dataDir.path)")

        let dataDirPath = config.dataDir.path
        // Gnosis RPC for the on-chain /wallet · /stamps · /chequebook
        // gateway surfaces. Present only in light mode; nil → those
        // endpoints stay bee zero-stubs (ultra-light browsing).
        let gnosisRpc = config.rpcEndpoint
        let transport = chainTransport
        let unverifiedLogs = unverifiedLogsRPC
        let swap = swapEnabled
        let initConfig = Self.initConfigJSON(cacheCapacityBytes: cacheCapacityBytes)

        Task.detached(priority: .userInitiated) { [weak self] in
            // Boot the node.
            var initErr: UnsafeMutablePointer<CChar>?
            let handle = dataDirPath.withCString { dir in
                initConfig.withCString { ant_init_with_config(dir, $0, &initErr) }
            }
            guard let handle else {
                let message = Self.takeError(initErr)
                await MainActor.run { self?.failStart(message, generation: myGeneration) }
                return
            }

            // Verified chain reads: install the host transport before
            // anything builds a chain client (the chequebook step below,
            // the gateway) so ant's Gnosis requests go through the app's
            // chain-data router instead of one pinned URL.
            var transportBox: Unmanaged<ChainTransportBox>?
            if let transport {
                let box = Unmanaged.passRetained(ChainTransportBox(transport))
                let rc = ant_set_chain_transport(handle, chainTransportCallback, box.toOpaque())
                if rc == ANT_CHAIN_TRANSPORT_OK {
                    transportBox = box
                    await MainActor.run { self?.append("chain transport: routed through the app's chain-data router") }
                } else {
                    box.release()
                    await MainActor.run { self?.append("chain transport not installed (rc=\(rc)); using the pinned RPC") }
                }
            }

            // Per-init switches ant does not persist.
            let swapRC = ant_set_swap_enabled(handle, swap, nil)
            var logsLine: String?
            if let unverifiedLogs {
                var logsErr: UnsafeMutablePointer<CChar>?
                let rc = unverifiedLogs.withCString { ant_set_unverified_logs_rpc(handle, $0, &logsErr) }
                logsLine = rc == 0 ? "unverified wallet-scan source: \(unverifiedLogs)" : "unverified wallet-scan source not set (rc=\(rc), \(Self.takeError(logsErr)))"
            }
            await MainActor.run {
                self?.append("swap: \(swap ? "on" : "off")\(swapRC == 0 ? "" : " (not applied, rc=\(swapRC))")")
                if let logsLine { self?.append(logsLine) }
            }

            // Serve the bee-compatible HTTP gateway in-process. Pass the
            // Gnosis RPC through so light mode gets live wallet/postage.
            var gwErr: UnsafeMutablePointer<CChar>?
            let served = Self.gatewayAuthority.withCString { addrPtr in
                if let gnosisRpc {
                    return gnosisRpc.withCString { rpcPtr in
                        ant_start_gateway(handle, addrPtr, lightMode, rpcPtr, &gwErr)
                    }
                }
                return ant_start_gateway(handle, addrPtr, lightMode, nil, &gwErr)
            }
            guard served else {
                let message = Self.takeError(gwErr)
                ant_shutdown(handle)
                await MainActor.run { self?.failStart(message, generation: myGeneration) }
                return
            }

            let wallet = Self.readWalletAddress(handle)

            _ = await MainActor.run { () -> Bool in
                guard let self else {
                    // Owner released mid-start — don't leak a live node.
                    Self.tearDown(handle, transportBox)
                    return false
                }
                guard self.lifecycleGeneration == myGeneration else {
                    // `stop()` (or another start) ran while we warmed up.
                    Self.tearDown(handle, transportBox)
                    self.append("start cancelled — discarding warmed-up node")
                    return false
                }
                self.node = handle
                self.chainTransportBox = transportBox
                self.walletAddress = wallet
                self.status = .running
                self.append("node running · gateway http://\(Self.gatewayAuthority) · wallet \(wallet)")
                self.startPolling()
                return true
            }

        }
    }

    /// Stop + shut down a node off the main actor. `ant_shutdown` (and a
    /// gateway stop) drain in-flight chain-transport callbacks, and those
    /// callbacks wait on the main actor — tearing down *on* it would
    /// deadlock the drain.
    private nonisolated static func tearDown(_ handle: OpaquePointer, _ box: Unmanaged<ChainTransportBox>?) {
        Task.detached(priority: .userInitiated) {
            ant_stop_gateway(handle)
            ant_shutdown(handle)
            box?.release()
        }
    }

    /// `{"registered":[...ids], "status": {...}}` → the ids.
    nonisolated static func registeredBatchIDs(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object["registered"] as? [String] ?? []
    }

    public func stop() {
        // Invalidate any in-flight start.
        lifecycleGeneration += 1
        guard let handle = node else {
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
        node = nil
        let box = chainTransportBox
        chainTransportBox = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            ant_stop_gateway(handle)
            // `ant_shutdown` drains every in-flight transport callback
            // before returning, so the context is safe to release after it.
            ant_shutdown(handle)
            box?.release()
            await MainActor.run {
                guard let self else { return }
                self.status = .stopped
                self.peerCount = 0
                self.walletScan = nil
                self.append("stopped")
            }
        }
    }

    /// Recover the in-process node after an iOS background suspension.
    ///
    /// A long suspension lets the OS reap the node's libp2p sockets
    /// without a FIN, so the peer count still *looks* healthy and the
    /// swarm's count-gated maintenance never re-dials — the next
    /// `bzz://` retrieval hangs and the page renders blank (ant #12).
    /// `ant_resume` forces a fresh bootstrap dial past those gates and
    /// leaves healthy peers untouched, so a short-background resume is
    /// ~a no-op. If the gateway's loopback listener was also torn down
    /// (`/health` unreachable), rebind it — `ant_resume` recovers the
    /// swarm only. Safe to call on every foreground; no-op unless the
    /// node is running.
    public func resume() async {
        guard status == .running, let handle = node else { return }
        var err: UnsafeMutablePointer<CChar>?
        let rc = ant_resume(handle, &err)
        if rc == 0 {
            append("resume: swarm redial kicked")
        } else {
            append("resume: ant_resume rc=\(rc) (\(Self.takeError(err)))")
        }
        if await !Self.gatewayHealthy() {
            // The node can vanish between the health check and here if a
            // stop()/restart raced; re-read rather than reuse `handle`.
            if let live = node { rebindGateway(live) }
        }
    }

    // MARK: - Storage plans (ant_storage_*)

    /// Price a plan: `ant_storage_quote` JSON (see `StorageQuote`).
    public func storageQuote(depth: UInt8, days: UInt64) async throws -> String {
        try await storageCall { handle, rpc, err in ant_storage_quote(handle, rpc, depth, days, err) }
    }

    /// Buy and activate a plan funded only with xDAI held by the node
    /// wallet. Submits real transactions and blocks until they confirm.
    public func storageBuyXdai(depth: UInt8, amountPerChunk: String, immutable: Bool) async throws -> String {
        try await storageCall { handle, rpc, err in
            amountPerChunk.withCString { ant_storage_buy_xdai(handle, rpc, depth, $0, immutable ? 1 : 0, err) }
        }
    }

    public func storageTopupQuote(days: UInt64) async throws -> String {
        try await storageCall { handle, rpc, err in ant_storage_topup_quote(handle, rpc, days, err) }
    }

    public func storageTopupXdai(amountPerChunk: String) async throws -> String {
        try await storageCall { handle, rpc, err in
            amountPerChunk.withCString { ant_storage_topup_xdai(handle, rpc, $0, err) }
        }
    }

    /// Deploy (or rediscover / reuse) the node's chequebook and switch
    /// settlement on. Idempotent; a deploy costs xDAI gas. Returns the
    /// chequebook address.
    public func deployChequebook() async throws -> String {
        try await storageCall { handle, rpc, err in ant_deploy_chequebook(handle, rpc, err) }
    }

    /// `ant_storage_status` JSON (the connected plan).
    public func storageStatus() async throws -> String {
        try await storageCall { handle, _, err in ant_storage_status(handle, err) }
    }

    /// `ant_storage_settlement_deposit` JSON (see `SettlementDeposit`).
    public func settlementDeposit() async throws -> String {
        try await storageCall { handle, rpc, err in ant_storage_settlement_deposit(handle, rpc, err) }
    }

    /// Fund the chequebook up to the settlement target from xDAI. Real
    /// transactions; blocks until confirmed.
    public func settlementTopup() async throws -> String {
        try await storageCall { handle, rpc, err in ant_storage_settlement_topup(handle, rpc, err) }
    }

    /// Run one `ant_storage_*` call off the main actor with the live
    /// handle and the storage RPC. ant returns a malloc'd JSON string or
    /// NULL plus an error string; both are freed here.
    private func storageCall(
        _ call: @escaping @Sendable (OpaquePointer, UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> UnsafeMutablePointer<CChar>?
    ) async throws -> String {
        guard let handle = node else { throw StorageError.notRunning }
        let rpc = storageRPC
        return try await Task.detached(priority: .userInitiated) { () throws -> String in
            var err: UnsafeMutablePointer<CChar>?
            let result: UnsafeMutablePointer<CChar>? = rpc.withCString { call(handle, $0, &err) }
            guard let result else { throw StorageError.failed(Self.takeError(err)) }
            defer { ant_free_string(result) }
            return String(cString: result)
        }.value
    }

    // MARK: - Internals

    /// `GET /health` with a tight timeout — true only on a live `200`.
    /// Used by `resume()` to decide whether the loopback listener
    /// survived the suspension.
    private nonisolated static func gatewayHealthy() async -> Bool {
        guard let url = URL(string: "http://\(gatewayAuthority)/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, response) = try? await URLSession.shared.data(for: req) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Rebind the in-process gateway after its loopback listener was
    /// reaped during suspension: `ant_stop_gateway` clears the dead serve
    /// task so `ant_start_gateway` can re-bind (and reload the persisted
    /// chequebook into the ChainContext). Reuses the last `start(_:)`
    /// config for light-mode / RPC.
    private func rebindGateway(_ handle: OpaquePointer) {
        let lightMode = lastConfig?.rpcEndpoint != nil
        let rpc = lastConfig?.rpcEndpoint
        // Off the main actor: a gateway handler mid chain-read holds a
        // transport callback that waits on the main actor (see `tearDown`).
        Task.detached(priority: .userInitiated) { [weak self] in
            ant_stop_gateway(handle)
            var err: UnsafeMutablePointer<CChar>?
            let served = Self.gatewayAuthority.withCString { addrPtr in
                if let rpc {
                    return rpc.withCString { ant_start_gateway(handle, addrPtr, lightMode, $0, &err) }
                }
                return ant_start_gateway(handle, addrPtr, lightMode, nil, &err)
            }
            let line = served ? "resume: gateway rebound" : "resume: gateway rebind failed (\(Self.takeError(err)))"
            await MainActor.run { self?.append(line) }
        }
    }

    private func failStart(_ message: String, generation: Int) {
        guard lifecycleGeneration == generation else { return }
        status = .failed
        append("start failed: \(message)")
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let handle = self.node else { break }
                let count = ant_peer_count(handle)
                self.peerCount = count < 0 ? 0 : Int(count)
                // Outer nil: /health unreadable, keep the last value.
                if let scan = await Self.readWalletScan(), scan != self.walletScan {
                    self.walletScan = scan
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// `ant_init_with_config`'s JSON: "" means every default (exactly
    /// `ant_init`). Unknown keys are an error in ant, so only set ones.
    public nonisolated static func initConfigJSON(cacheCapacityBytes: UInt64?) -> String {
        guard let cacheCapacityBytes else { return "" }
        return "{\"cache_capacity_bytes\":\(cacheCapacityBytes)}"
    }

    // MARK: - Chunk cache (ant v0.5.60)

    /// The cache's figures; nil while the node isn't running.
    public func cacheStatus() async -> SwarmCacheStatus? {
        guard let handle = node else { return nil }
        return await Task.detached { () -> SwarmCacheStatus? in
            var err: UnsafeMutablePointer<CChar>?
            guard let ptr = ant_cache_status(handle, &err) else {
                _ = Self.takeError(err)
                return nil
            }
            defer { ant_free_string(ptr) }
            return try? JSONDecoder().decode(SwarmCacheStatus.self, from: Data(String(cString: ptr).utf8))
        }.value
    }

    /// Set the cap now (evicting the oldest unpinned chunks down to it)
    /// and for every later start. Off the main thread: ant blocks until
    /// the eviction is done. Returns ant's error, if any; the new cap is
    /// applied even then (ant's contract), so keep the saved setting.
    @discardableResult
    public func setCacheCapacity(_ bytes: UInt64) async -> String? {
        cacheCapacityBytes = bytes
        guard let handle = node else { return nil }
        let line = await Task.detached { () -> String? in
            var err: UnsafeMutablePointer<CChar>?
            let rc = ant_cache_set_capacity(handle, bytes, &err)
            return rc == 0 ? nil : "rc=\(rc): \(Self.takeError(err))"
        }.value
        append(line.map { "cache cap not fully applied (\($0))" } ?? "cache cap: \(bytes) bytes")
        return line
    }

    public enum CacheError: Swift.Error, LocalizedError {
        case notRunning
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notRunning: "The Swarm node isn't running."
            case .failed(let message): message
            }
        }
    }

    /// Remove every unpinned chunk and give the space back to the OS
    /// where ant can. Pinned and published content stays.
    public func clearCache() async throws -> SwarmCacheClearResult {
        guard let handle = node else { throw CacheError.notRunning }
        let outcome = await Task.detached { () -> Result<SwarmCacheClearResult, CacheError> in
            var err: UnsafeMutablePointer<CChar>?
            guard let ptr = ant_cache_clear(handle, &err) else {
                return .failure(.failed(Self.takeError(err)))
            }
            defer { ant_free_string(ptr) }
            guard let result = try? JSONDecoder().decode(SwarmCacheClearResult.self, from: Data(String(cString: ptr).utf8)) else {
                return .failure(.failed("Unexpected answer from the Swarm node"))
            }
            return .success(result)
        }.value
        let result = try outcome.get()
        append("cache cleared: \(result.freedBytes) bytes freed, file \(result.fileBytesBefore) → \(result.fileBytesAfter) bytes")
        return result
    }

    /// Switch SWAP payments on the running node, and for every later start.
    public func setSwapEnabled(_ enabled: Bool) {
        swapEnabled = enabled
        guard let handle = node else { return }
        Task.detached { [weak self] in
            var err: UnsafeMutablePointer<CChar>?
            let rc = ant_set_swap_enabled(handle, enabled, &err)
            let line = rc == 0 ? "swap: \(enabled ? "on" : "off")" : "swap switch failed (rc=\(rc), \(Self.takeError(err)))"
            await MainActor.run { self?.append(line) }
        }
    }

    /// `/health.walletScan`: `.some(nil)` when the field is absent, nil
    /// when `/health` could not be read (keep the last value).
    private nonisolated static func readWalletScan() async -> WalletScan?? {
        guard let url = URL(string: "http://\(gatewayAuthority)/health") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct Health: Decodable { let walletScan: WalletScan? }
        guard let health = try? JSONDecoder().decode(Health.self, from: data) else { return nil }
        return .some(health.walletScan)
    }

    /// Read the node's Ethereum address from `ant_account_info`'s JSON
    /// (`{"eth_address","overlay","peer_id","agent"}`). Off-main; returns
    /// "" if the node can't report it.
    private nonisolated static func readWalletAddress(_ handle: OpaquePointer) -> String {
        var err: UnsafeMutablePointer<CChar>?
        guard let ptr = ant_account_info(handle, &err) else {
            _ = takeError(err)
            return ""
        }
        defer { ant_free_string(ptr) }
        let json = Data(String(cString: ptr).utf8)
        struct Account: Decodable { let eth_address: String }
        return (try? JSONDecoder().decode(Account.self, from: json))?.eth_address ?? ""
    }

    /// Copy + free an `out_err` C string written by the ant FFI.
    private nonisolated static func takeError(_ err: UnsafeMutablePointer<CChar>?) -> String {
        guard let err else { return "unknown error" }
        let message = String(cString: err)
        ant_free_string(err)
        return message
    }

    private func append(_ line: String) {
        let ts = Date().formatted(date: .omitted, time: .standard)
        log.append("\(ts)  \(line)")
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}


// MARK: - Chain transport plumbing

/// The `host_ctx` behind `ant_set_chain_transport`: owns the Swift
/// closure for as long as ant may call it.
final class ChainTransportBox: @unchecked Sendable {
    let serve: @Sendable (String) -> String?
    init(_ serve: @escaping @Sendable (String) -> String?) { self.serve = serve }
}

/// `ant_chain_transport` C entry point. Runs on ant's blocking pool; the
/// returned buffer is `malloc`'d (`strdup`) and freed by ant with `free(3)`.
private let chainTransportCallback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? = { request, ctx in
    guard let request, let ctx else { return nil }
    let box = Unmanaged<ChainTransportBox>.fromOpaque(ctx).takeUnretainedValue()
    guard let response = box.serve(String(cString: request)) else { return nil }
    return strdup(response)
}
