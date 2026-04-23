import Foundation

/// Single-shot JSON-RPC with fall-through across a chain's provider list.
/// Not consensus (that's ENS's job) — a lying RPC here gives the user a
/// wrong balance, not an attacker-chosen redirect, so the latency cost of
/// consensus isn't worth it.
@MainActor
struct WalletRPC {
    enum Error: Swift.Error {
        /// JSON-RPC error envelope returned by the provider. Deterministic
        /// across providers — retrying won't change the answer.
        case rpc(code: Int, message: String)
        /// Every URL in the chain's list failed at the transport layer.
        case allProvidersFailed([Swift.Error])
        /// Response had neither `result` nor `error`.
        case invalidResponse
        /// The chain has no URLs configured.
        case noProviders
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
            guard let result = envelope.result else {
                transportErrors.append(Error.invalidResponse)
                continue
            }
            return result
        }
        throw Error.allProvidersFailed(transportErrors)
    }

    /// Convenience for no-params calls like `eth_blockNumber`. Separate
    /// overload avoids the `params: [String]()` incantation at call sites.
    func call<R: Decodable>(_ method: String, on chain: Chain) async throws -> R {
        try await call(method, params: [String](), on: chain)
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

    private struct Request<P: Encodable>: Encodable {
        let jsonrpc: String = "2.0"
        let id: Int = 1
        let method: String
        let params: P
    }
}
