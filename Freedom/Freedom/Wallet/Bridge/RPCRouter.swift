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

    init(
        registry: ChainRegistry,
        permissionStore: PermissionStore,
        activeChain: @escaping @MainActor () -> Chain
    ) {
        self.registry = registry
        self.permissionStore = permissionStore
        self.activeChain = activeChain
    }

    /// Bridge helper — feeds gas estimation, broadcast, and the `connect`
    /// event payload (`.hexChainID`).
    func currentChain() -> Chain { activeChain() }

    func handle(method: String, params: [Any], origin: OriginIdentity) async throws -> Any {
        guard origin.isEligibleForWallet else {
            throw RouterError.unauthorized(method: method)
        }

        let chain = activeChain()

        switch method {
        case "eth_chainId":
            return chain.hexChainID
        case "net_version":
            return String(chain.id)
        case "eth_accounts":
            return permissionStore.accounts(for: origin.key)
        case "eth_blockNumber":
            let hex: String = try await registry.walletRPC.blockNumber(on: chain)
            return hex
        case "eth_getBalance":
            guard let address = params.first as? String else {
                throw RouterError.invalidParams(method: method, detail: "expected [address, blockTag]")
            }
            let hex: String = try await registry.walletRPC.balance(of: address, on: chain)
            return hex
        case "eth_call":
            return try await registry.walletRPC.callJSON(method: "eth_call", params: params, on: chain)

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
