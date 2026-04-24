import Foundation

/// Single-shot JSON-RPC with fall-through across a chain's provider list.
/// Not consensus (that's ENS's job) — a lying RPC here gives the user a
/// wrong balance, not an attacker-chosen redirect, so the latency cost of
/// consensus isn't worth it.
@MainActor
struct WalletRPC {
    enum Error: Swift.Error, LocalizedError {
        /// JSON-RPC error envelope returned by the provider. Deterministic
        /// across providers — retrying won't change the answer.
        case rpc(code: Int, message: String)
        /// Every URL in the chain's list failed at the transport layer.
        case allProvidersFailed([Swift.Error])
        /// Response had neither `result` nor `error`.
        case invalidResponse
        /// The chain has no URLs configured.
        case noProviders

        var errorDescription: String? {
            switch self {
            case .rpc(let code, let message):
                return "RPC \(code): \(message)"
            case .allProvidersFailed(let errors):
                let first = errors.first?.localizedDescription ?? "unknown cause"
                return "All \(errors.count) providers failed. \(first)"
            case .invalidResponse:
                return "Invalid response from all providers."
            case .noProviders:
                return "No RPC providers configured for this chain."
            }
        }
    }

    /// Single-URL transport. Takes pre-encoded JSON, returns the raw
    /// response body. Default delegates to `RPCSession.postBytes` with an
    /// 8s per-URL timeout (3 providers × 8s worst case fits inside a
    /// reasonable user-visible budget); tests inject a stub.
    typealias Transport = @Sendable (URL, Data) async throws -> Data

    let registry: ChainRegistry
    let transport: Transport

    init(registry: ChainRegistry, transport: @escaping Transport = WalletRPC.defaultTransport) {
        self.registry = registry
        self.transport = transport
    }

    nonisolated static let defaultTransport: Transport = { url, body in
        try await RPCSession.postBytes(url: url, body: body, timeout: 8)
    }

    func call<P: Encodable, R: Decodable>(
        _ method: String,
        params: P,
        on chain: Chain
    ) async throws -> R {
        // fanOut(allowNull: false) never returns nil — a nil result buckets
        // into transportErrors and eventually throws `allProvidersFailed`.
        try await fanOut(method: method, params: params, on: chain, allowNull: false)!
    }

    /// Convenience for no-params calls like `eth_blockNumber`. Separate
    /// overload avoids the `params: [String]()` incantation at call sites.
    func call<R: Decodable>(_ method: String, on chain: Chain) async throws -> R {
        try await call(method, params: [String](), on: chain)
    }

    /// Like `call`, but treats a `null` RPC result as a valid response —
    /// returning `nil` — rather than as a malformed response. Use for
    /// methods like `eth_getTransactionByHash` where "null" means "not
    /// found / still pending" and is the well-defined absence case.
    func callOptional<P: Encodable, R: Decodable>(
        _ method: String,
        params: P,
        on chain: Chain
    ) async throws -> R? {
        try await fanOut(method: method, params: params, on: chain, allowNull: true)
    }

    /// Shared provider-fan-out: encodes the request once, iterates URLs,
    /// buckets transport / decoding errors, throws on RPC-level errors
    /// without retrying. `allowNull` controls whether an envelope with
    /// `"result": null` is treated as a successful nil response (used by
    /// methods like `eth_getTransactionByHash`) or as malformed and
    /// retry-the-next-URL (every other caller).
    private func fanOut<P: Encodable, R: Decodable>(
        method: String,
        params: P,
        on chain: Chain,
        allowNull: Bool
    ) async throws -> R? {
        let body = try RPCSession.encoder.encode(Request(method: method, params: params))
        let urls = registry.rpcURLs(for: chain)
        guard !urls.isEmpty else { throw Error.noProviders }

        var transportErrors: [Swift.Error] = []
        for url in urls {
            let data: Data
            do {
                data = try await transport(url, body)
            } catch {
                transportErrors.append(error)
                continue
            }
            let envelope: RPCSession.Response<R>
            do {
                envelope = try RPCSession.decoder.decode(RPCSession.Response<R>.self, from: data)
            } catch {
                transportErrors.append(error)
                continue
            }
            if let err = envelope.error {
                throw Error.rpc(code: err.code, message: err.message)
            }
            if let result = envelope.result {
                return result
            }
            if allowNull {
                return nil
            }
            transportErrors.append(Error.invalidResponse)
        }
        throw Error.allProvidersFailed(transportErrors)
    }

    // MARK: - Typed methods

    func balance(of address: String, on chain: Chain) async throws -> String {
        try await call("eth_getBalance", params: [address, "latest"], on: chain)
    }

    func blockNumber(on chain: Chain) async throws -> String {
        try await call("eth_blockNumber", on: chain)
    }

    func chainID(on chain: Chain) async throws -> String {
        try await call("eth_chainId", on: chain)
    }

    func gasPrice(on chain: Chain) async throws -> String {
        try await call("eth_gasPrice", on: chain)
    }

    /// `"pending"` tag — counts in-mempool txs so we don't collide with our
    /// own outstanding sends.
    func transactionCount(of address: String, on chain: Chain) async throws -> String {
        try await call("eth_getTransactionCount", params: [address, "pending"], on: chain)
    }

    func estimateGas(
        from: String,
        to: String,
        valueHex: String,
        dataHex: String,
        on chain: Chain
    ) async throws -> String {
        let tx: [String: String] = ["from": from, "to": to, "value": valueHex, "data": dataHex]
        return try await call("eth_estimateGas", params: [tx], on: chain)
    }

    func sendRawTransaction(rawHex: String, on chain: Chain) async throws -> String {
        try await call("eth_sendRawTransaction", params: [rawHex], on: chain)
    }

    struct TransactionInfo: Decodable {
        /// Hex block number, or nil while the tx is still in the mempool.
        let blockNumber: String?
    }

    /// `eth_getTransactionByHash` returns `null` for unknown-or-pending txs.
    /// `callOptional` treats that nil as success-with-nil rather than as a
    /// malformed envelope.
    func getTransaction(hash: String, on chain: Chain) async throws -> TransactionInfo? {
        try await callOptional("eth_getTransactionByHash", params: [hash], on: chain)
    }

    private struct Request<P: Encodable>: Encodable {
        let jsonrpc: String = "2.0"
        let id: Int = 1
        let method: String
        let params: P
    }
}
