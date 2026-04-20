import Foundation
import Observation
import Mobile

public enum SwarmStatus: String, Sendable {
    case idle, starting, running, stopping, stopped, failed
}

public struct SwarmConfig: Sendable {
    public var dataDir: URL
    public var password: String
    public var rpcEndpoint: String?       // nil → ultra-light mode
    public var bootnodes: String
    public var mainnet: Bool
    public var networkID: Int64

    public init(
        dataDir: URL,
        password: String,
        rpcEndpoint: String? = nil,
        bootnodes: String = "/dnsaddr/mainnet.ethswarm.org",
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

    private var node: MobileMobileNodeProtocol?
    private var pollTask: Task<Void, Never>?

    public init() {}

    public func start(_ config: SwarmConfig) {
        guard node == nil else { return }
        status = .starting
        append("starting bee-lite (\(config.rpcEndpoint == nil ? "ultra-light" : "light"))…")

        try? FileManager.default.createDirectory(at: config.dataDir, withIntermediateDirectories: true)
        append("dataDir: \(config.dataDir.path)")

        let options = Self.buildOptions(config)
        let password = config.password

        Task.detached(priority: .userInitiated) { [weak self] in
            var err: NSError?
            let n = MobileStartNode(options, password, "3", &err)
            await MainActor.run {
                guard let self else { return }
                if let n {
                    self.node = n
                    self.walletAddress = n.walletAddress()
                    self.status = .running
                    self.append("node running · wallet \(self.walletAddress)")
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

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let node = self.node else { break }
                let count = node.connectedPeerCount()
                self.peerCount = count
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func append(_ line: String) {
        let ts = Date().formatted(date: .omitted, time: .standard)
        log.append("\(ts)  \(line)")
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    private static func buildOptions(_ c: SwarmConfig) -> MobileMobileNodeOptions {
        let o = MobileMobileNodeOptions()
        o.fullNodeMode = false
        o.bootnodeMode = false
        o.bootnodes = c.bootnodes
        o.staticNodes = ""
        o.dataDir = c.dataDir.path
        o.welcomeMessage = "swarm-mobile-ios"
        o.blockchainRpcEndpoint = c.rpcEndpoint ?? ""
        o.swapInitialDeposit = "0"
        o.paymentThreshold = "100000000"
        o.swapEnable = c.rpcEndpoint != nil
        o.chequebookEnable = c.rpcEndpoint != nil
        o.usePostageSnapshot = false
        o.mainnet = c.mainnet
        o.networkID = c.networkID
        o.natAddr = ""
        o.cacheCapacity = c.rpcEndpoint == nil ? 0 : 32 * 1024 * 1024
        o.dbOpenFilesLimit = 50
        o.dbWriteBufferSize = 32 * 1024 * 1024
        o.dbBlockCacheCapacity = 32 * 1024 * 1024
        o.dbDisableSeeksCompaction = false
        o.retrievalCaching = true
        return o
    }
}
