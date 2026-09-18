import Foundation
import OSLog

private let log = Logger(subsystem: "com.browser.Freedom", category: "OnchainApp")

/// Fetches an ERC-8244 document: one `eth_call` of `html()` at `latest`
/// through the chain-data router with the app's permission key as the
/// routing context — the same ladder every read uses (Myotis, Colibri,
/// quorum, direct), with the interactive budget a page-driven read
/// gets, and *who answered* on the result. The gate below needs that
/// provenance: a document only a public RPC vouched for must not run
/// until the user says so, and one that endpoints disagreed about must
/// not run at all.
@MainActor
final class OnchainAppLoader {
    private let registry: ChainRegistry
    private let chainStore: ChainStore

    init(registry: ChainRegistry, chainStore: ChainStore) {
        self.registry = registry
        self.chainStore = chainStore
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
        let result: ChainDataResult
        do {
            result = try await registry.chainData.request(
                chainID: chain.id,
                method: "eth_call",
                params: params,
                context: RoutingContext(origin: app.permissionKey),
                options: .init(rejectNull: true, directOnly: Self.debugForceDirect)
            )
        } catch WalletRPC.Error.rpc(_, let message) {
            // A revert (verified or from an endpoint) is the contract's
            // answer: not an app.
            throw OnchainAppError.notAnApp(detail: message)
        } catch let error as WalletRPC.Error {
            log.info("[onchain] html() chain=\(chain.id) failed: \(error.errorDescription ?? "", privacy: .public)")
            throw OnchainAppError.unreachable
        }
        guard let hex = result.result as? String else { throw OnchainAppError.unreachable }
        let html = try OnchainAppRef.decodeHTML(hex)
        log.info(
            "[onchain] html() chain=\(chain.id) via \(result.source.rawValue, privacy: .public) \(result.trust.level.displayName, privacy: .public) dissent=\(result.trust.dissented.count)"
        )
        return OnchainAppDocument(
            html: html,
            provenance: OnchainAppProvenance(
                app: app,
                networkName: chain.displayName,
                htmlHash: OnchainAppRef.htmlHash(html),
                trust: result.trust
            )
        )
    }

    /// Smoke-test hook (DEBUG builds only): `FREEDOM_DEBUG_ONCHAIN_DIRECT=1`
    /// skips the verified tiers so the unverified path and its
    /// interstitial can be exercised on a simulator whose Colibri or
    /// Myotis would otherwise verify every mainnet read.
    private static var debugForceDirect: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["FREEDOM_DEBUG_ONCHAIN_DIRECT"] == "1"
        #else
        return false
        #endif
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
