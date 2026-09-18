import Foundation

/// Typed façade over `ChainDataRouter` for wallet-internal reads:
/// `Encodable` params in, `Decodable` results out, provenance dropped.
/// The router walks the chain's policy (Myotis → Colibri → quorum →
/// direct); the error cases below are what its walk reports.
@MainActor
struct WalletRPC {
    enum Error: Swift.Error, LocalizedError {
        /// Protocol-deterministic answer from a provider — execution
        /// revert (`error.data` populated) or `-32602 invalid params`.
        case rpc(code: Int, message: String)
        /// Sender can't cover `value + gas`. Deterministic — every
        /// provider rejects the same way.
        case insufficientFunds(message: String)
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
            case .insufficientFunds(let message):
                return message
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

    /// Single-URL transport as the wallet tests inject it: pre-encoded
    /// JSON in, raw response body out. The router's own transport
    /// additionally takes the per-source timeout; a wrapped test
    /// transport ignores it.
    typealias Transport = @Sendable (URL, Data) async throws -> Data

    /// The router every read goes through. Exposed so the dapp bridge
    /// and the onchain-app loader can route with a page context and
    /// still share this instance's transport (tests inject one here).
    let router: ChainDataRouter

    /// Production: the router with its default timeout-aware transport.
    init(registry: ChainRegistry) {
        self.router = ChainDataRouter(registry: registry)
    }

    /// Tests: a two-argument transport stub, wrapped for the router.
    init(registry: ChainRegistry, transport: @escaping Transport) {
        self.router = ChainDataRouter(registry: registry, transport: { url, body, _ in
            try await transport(url, body)
        })
    }

    init(router: ChainDataRouter) {
        self.router = router
    }

    func call<P: Encodable, R: Decodable>(
        _ method: String,
        params: P,
        on chain: Chain
    ) async throws -> R {
        let result = try await router.request(
            chainID: chain.id,
            method: method,
            params: try Self.jsonParams(params),
            options: .init(rejectNull: true)
        ).result
        guard let value: R = Self.decode(result) else { throw Error.invalidResponse }
        return value
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
        let result = try await router.request(
            chainID: chain.id,
            method: method,
            params: try Self.jsonParams(params)
        ).result
        if result is NSNull { return nil }
        guard let value: R = Self.decode(result) else { throw Error.invalidResponse }
        return value
    }

    /// `Encodable` params → the Foundation JSON array the router and its
    /// sources work on. One round trip through `JSONEncoder`, so the
    /// bytes every tier sees are the ones the typed API always sent.
    private static func jsonParams<P: Encodable>(_ params: P) throws -> [Any] {
        let data = try RPCSession.encoder.encode(params)
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return object as? [Any] ?? []
    }

    /// Foundation JSON value → the caller's `Decodable`. Nil when the
    /// shape does not match (a provider quirk the caller reports as
    /// `invalidResponse`).
    private static func decode<R: Decodable>(_ value: Any) -> R? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
            return nil
        }
        return try? RPCSession.decoder.decode(R.self, from: data)
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

    struct BlockHeader: Decodable {
        /// Hex wei, or nil on pre-London chains that have no base fee.
        let baseFeePerGas: String?
    }

    /// Latest block header — `false` requests tx hashes only, we never
    /// read the tx list.
    func latestBlockHeader(on chain: Chain) async throws -> BlockHeader {
        try await call(
            "eth_getBlockByNumber",
            params: [Param.string("latest"), .bool(false)],
            on: chain
        )
    }

    /// Positional JSON-RPC params mix types (`["latest", false]`), which
    /// a homogeneous `[String]` can't express.
    enum Param: Encodable {
        case string(String)
        case bool(Bool)

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let s): try container.encode(s)
            case .bool(let b): try container.encode(b)
            }
        }
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

    /// Untyped JSON pass-through for the EIP-1193 bridge. Dapp-supplied
    /// params (e.g. `eth_call`) have open-ended shapes we can't statically
    /// type, so params + return are `Any` / `[Any]` and we encode via
    /// `JSONSerialization` instead of `Encodable`.
    func callJSON(method: String, params: [Any], on chain: Chain) async throws -> Any {
        try await router.request(chainID: chain.id, method: method, params: params).result
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
}
