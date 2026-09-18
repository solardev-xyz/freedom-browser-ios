import Foundation

/// EIP-1193 method dispatch — routes dapp requests for the connected
/// tab's origin. Gated vs. refused is the key distinction: gated methods
/// (connect, sign, send, chain-switch) return 4100 so the dapp gets a
/// "connect first" signal and can retry; refused methods (`eth_sign`,
/// `eth_signTransaction`, `wallet_addEthereumChain`) return 4200 because
/// they'll never succeed no matter what the user does.
@MainActor
final class RPCRouter {
    enum RouterError: Swift.Error, Equatable {
        case unauthorized(method: String)         // 4100
        case unsupportedMethod(method: String)    // 4200
        case invalidParams(method: String, detail: String)  // -32602
    }

    struct ErrorPayload: Equatable {
        let code: Int
        let message: String

        /// EIP-1193 + EIP-1474 + EIP-3326 error codes. Grouped here so the
        /// magic numbers in bridge handlers map back to a spec reference.
        enum Code {
            static let userRejected = 4001         // EIP-1193 §5.1
            static let unauthorized = 4100         // EIP-1193 §5.1
            static let unsupportedMethod = 4200    // EIP-1193 §5.1
            static let unrecognizedChain = 4902    // EIP-3326
            static let resourceUnavailable = -32002 // EIP-1474
            static let invalidParams = -32602      // EIP-1474
            static let internalError = -32603      // EIP-1474
        }
    }

    @ObservationIgnored private let registry: ChainRegistry
    @ObservationIgnored private let permissionStore: PermissionStore
    private let activeChain: @MainActor () -> Chain
    private let pinnedChainSource: @MainActor () -> Chain?

    init(
        registry: ChainRegistry,
        permissionStore: PermissionStore,
        activeChain: @escaping @MainActor () -> Chain,
        pinnedChain: @escaping @MainActor () -> Chain? = { nil }
    ) {
        self.registry = registry
        self.permissionStore = permissionStore
        self.activeChain = activeChain
        self.pinnedChainSource = pinnedChain
    }

    /// Bridge helper — feeds gas estimation, broadcast, and the `connect`
    /// event payload (`.hexChainID`). A contract-hosted app's pinned
    /// chain (the one in its origin) wins over the wallet's global
    /// active chain, so the app never sees reads or signatures for a
    /// chain it wasn't deployed on.
    func currentChain() -> Chain { pinnedChainSource() ?? activeChain() }

    /// Non-nil while the tab is on an onchain app.
    func pinnedChain() -> Chain? { pinnedChainSource() }

    func handle(method: String, params: [Any], origin: OriginIdentity) async throws -> Any {
        guard origin.isEligibleForWallet else {
            throw RouterError.unauthorized(method: method)
        }

        let chain = currentChain()

        switch method {
        case "eth_chainId":
            return chain.hexChainID
        case "net_version":
            return String(chain.id)
        case "eth_accounts":
            return permissionStore.accounts(for: origin.key)
        // Page-driven reads carry the page's permission key so the
        // chain-data router treats them as interactive: a slow verified
        // source falls through after its interactive budget instead of
        // stalling the page.
        case "eth_blockNumber":
            return try await read(method, params: [], chain: chain, origin: origin)
        case "eth_getBalance":
            guard let address = params.first as? String else {
                throw RouterError.invalidParams(method: method, detail: "expected [address, blockTag]")
            }
            let tag = params.count > 1 ? params[1] : "latest"
            return try await read(method, params: [address, tag], chain: chain, origin: origin)
        case "eth_call":
            return try await read(method, params: params, chain: chain, origin: origin)

        case "eth_requestAccounts", "enable",
             "personal_sign", "eth_signTypedData_v4",
             "eth_sendTransaction", "wallet_switchEthereumChain":
            throw RouterError.unauthorized(method: method)

        case "eth_sign", "eth_signTransaction", "wallet_addEthereumChain":
            throw RouterError.unsupportedMethod(method: method)

        default:
            throw RouterError.unsupportedMethod(method: method)
        }
    }

    private func read(_ method: String, params: [Any], chain: Chain, origin: OriginIdentity) async throws -> Any {
        try await registry.chainData.request(
            chainID: chain.id, method: method, params: params, context: RoutingContext(origin: origin.key)
        ).result
    }

    func errorPayload(for error: Swift.Error) -> ErrorPayload {
        if let e = error as? RouterError {
            switch e {
            case .unauthorized(let m):
                return ErrorPayload(code: 4100, message: "Unauthorized: \(m)")
            case .unsupportedMethod(let m):
                return ErrorPayload(code: 4200, message: "Method not supported: \(m)")
            case .invalidParams(let m, let detail):
                return ErrorPayload(code: -32602, message: "Invalid params for \(m): \(detail)")
            }
        }
        if let rpc = error as? WalletRPC.Error {
            if case .rpc(let code, let message) = rpc {
                return ErrorPayload(code: code, message: message)
            }
            return ErrorPayload(code: -32603, message: rpc.errorDescription ?? "internal error")
        }
        return ErrorPayload(code: -32603, message: "\(error)")
    }
}
