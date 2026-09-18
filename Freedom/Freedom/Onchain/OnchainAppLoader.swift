import Foundation
import OSLog

private let log = Logger(subsystem: "com.browser.Freedom", category: "OnchainApp")

/// Fetches an ERC-8244 document: one `eth_call` of `html()` at `latest`
/// through the same ladder the wallet's reads use — the verified sources
/// (Myotis, Colibri) first, then the chain's direct RPC pool — but
/// keeping *who answered*. Desktop's chain-data router returns that
/// provenance on every read; the wallet path on iOS strips it, and the
/// gate below needs it: a document only a public RPC vouched for must
/// not run until the user says so.
@MainActor
final class OnchainAppLoader {
    typealias Transport = @Sendable (URL, Data, TimeInterval) async throws -> Data

    private let registry: ChainRegistry
    private let chainStore: ChainStore
    private let transport: Transport

    /// Per-endpoint budget on the direct tier; the whole load is bounded
    /// by `OnchainAppRef.requestTimeout`.
    static let directTimeout: TimeInterval = 10

    init(
        registry: ChainRegistry,
        chainStore: ChainStore,
        transport: @escaping Transport = { url, body, timeout in
            try await RPCSession.postBytes(url: url, body: body, timeout: timeout)
        }
    ) {
        self.registry = registry
        self.chainStore = chainStore
        self.transport = transport
    }

    func load(_ app: OnchainAppRef) async throws -> OnchainAppDocument {
        guard let chain = chainStore.chain(id: app.chainID) else {
            throw OnchainAppError.unknownChain(chainID: app.chainID)
        }
        do {
            return try await RPCSession.withTimeout(seconds: OnchainAppRef.requestTimeout) {
                try await self.fetch(app, chain: chain)
            }
        } catch let error as OnchainAppError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw OnchainAppError.timedOut
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OnchainAppError.unreachable
        }
    }

    private func fetch(_ app: OnchainAppRef, chain: Chain) async throws -> OnchainAppDocument {
        let call: [String: Any] = ["to": app.address, "data": OnchainAppRef.htmlSelector]
        let params: [Any] = [call, "latest"]

        // Verified sources: a proven revert is a deterministic answer
        // ("not an app"); anything else falls through to the next source.
        for source in registry.verifiedSources
        where source.isAvailable(chainID: chain.id)
            && source.serves(method: "eth_call", params: params, chainID: chain.id)
        {
            try Task.checkCancellation()
            do {
                let result = try await source.result(method: "eth_call", params: params, chainID: chain.id)
                guard let hex = result as? String else { continue }
                let html = try OnchainAppRef.decodeHTML(hex)
                log.info("[onchain] html() chain=\(chain.id) via \(source.sourceName, privacy: .public)")
                return document(html: html, app: app, chain: chain, trust: Self.verifiedTrust(source: source.sourceName))
            } catch let error as WalletRPC.Error {
                throw OnchainAppError.notAnApp(detail: error.errorDescription ?? "execution reverted")
            } catch let error as OnchainAppError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.info("[onchain] \(source.sourceName, privacy: .public) unavailable: \(String(describing: error), privacy: .public) — falling through")
                continue
            }
        }

        // Direct tier: the first public endpoint that answers, labelled
        // unverified. Transport / malformed failures quarantine the
        // endpoint; a revert is the contract's answer and ends the walk.
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "eth_call", "params": params,
        ])
        let urls = registry.rpcURLs(for: chain)
        for url in urls {
            try Task.checkCancellation()
            let data: Data
            do {
                data = try await transport(url, body, Self.directTimeout)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                registry.markFailure(url: url, on: chain)
                continue
            }
            guard let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                registry.markFailure(url: url, on: chain)
                continue
            }
            if let error = envelope["error"] as? [String: Any] {
                if error["data"] != nil {
                    throw OnchainAppError.notAnApp(detail: (error["message"] as? String) ?? "execution reverted")
                }
                // Endpoint-level refusal (rate limit, method unsupported):
                // not the contract's answer, try the next endpoint.
                continue
            }
            guard let hex = envelope["result"] as? String else {
                registry.markFailure(url: url, on: chain)
                continue
            }
            registry.markSuccess(url: url, on: chain)
            let html = try OnchainAppRef.decodeHTML(hex)
            log.info("[onchain] html() chain=\(chain.id) via direct \(url.hostOrAbsolute, privacy: .public) (unverified)")
            return document(html: html, app: app, chain: chain, trust: Self.directTrust(endpoint: url))
        }
        throw OnchainAppError.unreachable
    }

    private func document(html: String, app: OnchainAppRef, chain: Chain, trust: ENSTrust) -> OnchainAppDocument {
        OnchainAppDocument(
            html: html,
            provenance: OnchainAppProvenance(
                app: app,
                networkName: chain.displayName,
                htmlHash: OnchainAppRef.htmlHash(html),
                trust: trust
            )
        )
    }

    static func verifiedTrust(source: String) -> ENSTrust {
        let method: ENSResolutionMethod = source == "myotis" ? .myotis : .colibri
        let label = source == "myotis" ? ENSResolver.myotisProviderLabel : source
        return ENSTrust(
            level: .verified, method: method,
            block: ENSBlock(number: 0, hash: ""),
            agreed: [label], dissented: [], queried: [label], k: 1, m: 1
        )
    }

    static func directTrust(endpoint: URL) -> ENSTrust {
        let host = endpoint.hostOrAbsolute
        return ENSTrust(
            level: .unverified, method: .quorum,
            block: ENSBlock(number: 0, hash: ""),
            agreed: [host], dissented: [], queried: [host], k: 1, m: 1
        )
    }
}

/// Process-lifetime memory of documents the user chose to run despite
/// an unverified fetch. Keyed by chain + contract + exact HTML hash, so
/// changed bytes warn again; never persisted (desktop parity).
@MainActor
final class OnchainApprovals {
    static let shared = OnchainApprovals()

    static let capacity = 1024
    private var approved: [String] = []
    private var index: Set<String> = []

    init() {}

    private static func key(_ p: OnchainAppProvenance) -> String {
        "\(p.app.chainID):\(p.app.lowercasedAddress):\(p.htmlHash.lowercased())"
    }

    func isApproved(_ provenance: OnchainAppProvenance) -> Bool {
        index.contains(Self.key(provenance))
    }

    func approve(_ provenance: OnchainAppProvenance) {
        let key = Self.key(provenance)
        guard !index.contains(key) else { return }
        if approved.count >= Self.capacity {
            let evicted = approved.removeFirst()
            index.remove(evicted)
        }
        approved.append(key)
        index.insert(key)
    }
}

/// The chain an onchain-app tab is pinned to. Shared between the tab and
/// its `RPCRouter` so every EIP-1193 read, gas estimate and signature
/// for the app happens on the chain in its origin, whatever the wallet's
/// global active chain is.
@MainActor
final class OnchainChainPin {
    var chainID: Int?
    init() {}
}
