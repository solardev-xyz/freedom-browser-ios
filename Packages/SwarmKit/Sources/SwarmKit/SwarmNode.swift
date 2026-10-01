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
    public var rpcEndpoint: String?       // nil → ultra-light mode
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

@MainActor
@Observable
public final class SwarmNode {
    public private(set) var status: SwarmStatus = .idle
    public private(set) var peerCount: Int = 0
    public private(set) var walletAddress: String = ""
    public private(set) var log: [String] = []

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
    /// Owned batches discovered on-chain at the last start (`ant_storage_discover`).
    public private(set) var discoveredBatches: [String] = []
    /// Gnosis RPC handed to the `ant_storage_*` calls as their fallback
    /// transport (the installed chain transport answers first). Needed
    /// in every mode: storage can be bought while the node still browses
    /// ultra-light.
    public var storageRPC: String = "https://rpc.gnosischain.com"

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

        Task.detached(priority: .userInitiated) { [weak self] in
            // Boot the node.
            var initErr: UnsafeMutablePointer<CChar>?
            let handle = dataDirPath.withCString { ant_init($0, &initErr) }
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

            // Light mode: deploy (or rediscover / reuse) the node's
            // chequebook BEFORE serving, so the gateway's ChainContext
            // reports it and publish-setup's "chequebook deployed" step
            // advances. Idempotent — returns the persisted/rediscovered
            // address with no on-chain tx when one already exists (incl.
            // one the same vault deployed on desktop). Best-effort: a
            // failure (no xDAI for gas, RPC down) is non-fatal; the node
            // still serves so browsing works.
            if lightMode, let gnosisRpc {
                var cbErr: UnsafeMutablePointer<CChar>?
                let cbResult: String? = gnosisRpc.withCString { rpcPtr in
                    guard let ptr = ant_deploy_chequebook(handle, rpcPtr, &cbErr) else { return nil }
                    defer { ant_free_string(ptr) }
                    return String(cString: ptr)
                }
                let line = cbResult.map { "chequebook ready · \($0)" }
                    ?? "chequebook deploy skipped: \(Self.takeError(cbErr))"
                await MainActor.run { self?.append(line) }
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

            let adopted = await MainActor.run { () -> Bool in
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

            // Light mode: adopt funded batches this account owns on-chain
            // but has no local issuer for (antd's startup step 3 — a
            // reinstall, or a batch bought on desktop with the same
            // vault). A log scan, so it runs after the node is serving
            // and never blocks browsing; best-effort like antd.
            // Re-check right before the call: a `stop()` in between would
            // shut the handle down under us (ant drains calls already in
            // flight, but a call must not *start* on a freed handle).
            var stillOurs = false
            if adopted { stillOurs = await MainActor.run { self?.node == handle } }
            if stillOurs, lightMode, let gnosisRpc {
                var discErr: UnsafeMutablePointer<CChar>?
                let json: String? = gnosisRpc.withCString { rpcPtr in
                    guard let ptr = ant_storage_discover(handle, rpcPtr, &discErr) else { return nil }
                    defer { ant_free_string(ptr) }
                    return String(cString: ptr)
                }
                let ids = json.flatMap(Self.registeredBatchIDs) ?? []
                let line = json != nil
                    ? "batch discovery: \(ids.count) owned batch\(ids.count == 1 ? "" : "es") registered"
                    : "batch discovery skipped: \(Self.takeError(discErr))"
                await MainActor.run {
                    guard let self, self.lifecycleGeneration == myGeneration else { return }
                    self.discoveredBatches = ids
                    self.append(line)
                }
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
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
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
