import Foundation
import Observation
// The combined freedom-node-mobile binding emits a single `Mobile`
// framework module containing both bee (`MobileMobile*`) and kubo
// (`MobileIpfs*`) Obj-C surfaces. SwarmKit also imports this module.
import Mobile

public enum IPFSStatus: String, Sendable {
    case idle, starting, running, stopping, stopped, failed
}

public enum IPFSError: LocalizedError {
    case notRunning
    case startFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning: "IPFS node is not running"
        case .startFailed(let message): "IPFS node failed to start: \(message)"
        }
    }
}

public enum IPFSRoutingMode: String, Sendable, CaseIterable {
    case dht         = "dht"
    case dhtclient   = "dhtclient"
    case autoclient  = "autoclient"
    /// "none" — content routing fully off. Avoid the bare `.none` Swift
    /// case name to keep this from colliding with `Optional.none` at use
    /// sites; the rawValue still matches what the Go wrapper expects.
    case disabled    = "none"
}

public struct IPFSConfig: Sendable {
    public var dataDir: URL
    public var gatewayHost: String
    public var gatewayPort: Int
    public var lowPower: Bool
    public var routingMode: IPFSRoutingMode
    public var offline: Bool

    public init(
        dataDir: URL,
        gatewayHost: String = "127.0.0.1",
        gatewayPort: Int = 5050,
        lowPower: Bool = true,
        routingMode: IPFSRoutingMode = .autoclient,
        offline: Bool = false
    ) {
        self.dataDir = dataDir
        self.gatewayHost = gatewayHost
        self.gatewayPort = gatewayPort
        self.lowPower = lowPower
        self.routingMode = routingMode
        self.offline = offline
    }

    public var gatewayAddr: String { "\(gatewayHost):\(gatewayPort)" }
}

@MainActor
@Observable
public final class IPFSNode {
    public private(set) var status: IPFSStatus = .idle
    public private(set) var peerCount: Int = 0
    public private(set) var peerID: String = ""
    public private(set) var gatewayURL: URL?
    public private(set) var log: [String] = []

    // gomobile-bound types live in the `Kubo` framework module under
    // the Go-package-derived `Mobile*` prefix (because the Go package
    // is named `mobile`). Same shape as SwarmKit's MobileMobileNode.
    private var node: MobileIpfsNodeProtocol?
    private var pollTask: Task<Void, Never>?

    public init() {}

    public static func defaultDataDir() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ipfs", isDirectory: true)
    }

    public func start(_ config: IPFSConfig) {
        guard node == nil else { return }
        status = .starting
        append("starting kubo (\(config.routingMode.rawValue), \(config.lowPower ? "lowpower" : "default"))…")

        try? FileManager.default.createDirectory(at: config.dataDir, withIntermediateDirectories: true)
        append("dataDir: \(config.dataDir.path)")

        let options = Self.buildOptions(config)
        let projectedGatewayURL = URL(string: "http://\(config.gatewayAddr)")

        Task.detached(priority: .userInitiated) { [weak self] in
            var err: NSError?
            // MobileStartIpfsNode is synchronous on the Go side; it waits
            // for the corehttp gateway to signal "ready" before returning.
            // Run on a background thread so a slow plugin-init or libp2p
            // bring-up doesn't stall the main actor on cold launch.
            let n = MobileStartIpfsNode(options, "info", &err)
            await MainActor.run {
                guard let self else { return }
                if let n {
                    self.node = n
                    self.peerID = n.peerID()
                    self.gatewayURL = projectedGatewayURL
                    self.status = .running
                    let pid = self.peerID.isEmpty ? "(unassigned)" : String(self.peerID.prefix(12)) + "…"
                    self.append("node running · peer \(pid)")
                    self.startPolling()
                } else {
                    self.status = .failed
                    self.append("start failed: \(err?.localizedDescription ?? "unknown error")")
                }
            }
        }
    }

    public func stop() {
        guard let n = node else { return }
        status = .stopping
        append("shutting down…")
        pollTask?.cancel()
        pollTask = nil
        let captured = n
        node = nil
        gatewayURL = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try captured.shutdown()
                await MainActor.run {
                    self?.status = .stopped
                    self?.peerCount = 0
                    self?.append("stopped")
                }
            } catch {
                await MainActor.run {
                    self?.status = .failed
                    self?.append("shutdown failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Pin `data` into the local kubo blockstore. Returns the resulting
    /// `/ipfs/<cid>` path. The pin is local-only — does not provide the
    /// CID to the DHT.
    public func add(_ data: Data) async throws -> String {
        guard let captured = node else { throw IPFSError.notRunning }
        return try await withUnsafeThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                // gomobile annotates the Obj-C return as `_Nonnull`, so
                // Swift's `error:` → `throws` bridging is not applied;
                // the method signature is `addBytes(_:error:) -> String`.
                // Use the explicit error-pointer pattern instead.
                var err: NSError?
                let path = captured.addBytes(data, error: &err)
                if let err {
                    cont.resume(throwing: err)
                } else {
                    cont.resume(returning: path)
                }
            }
        }
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let node = self.node else { break }
                self.peerCount = Int(node.connectedPeerCount())
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func append(_ line: String) {
        let ts = Date().formatted(date: .omitted, time: .standard)
        log.append("\(ts)  \(line)")
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    private static func buildOptions(_ c: IPFSConfig) -> MobileIpfsNodeOptions {
        let o = MobileIpfsNodeOptions()
        o.dataDir = c.dataDir.path
        o.gatewayAddr = c.gatewayAddr
        o.offline = c.offline
        o.lowPower = c.lowPower
        o.routingMode = c.routingMode.rawValue
        return o
    }
}
