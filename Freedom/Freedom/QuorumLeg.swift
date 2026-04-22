import Foundation
import web3

enum QuorumLeg {
    struct Outcome {
        let url: URL
        let kind: Kind

        enum Kind {
            case data(resolvedData: Data, resolverAddress: EthereumAddress)
            case notFound(reason: ENSNotFoundReason)
            case error(Error)
        }
    }

    /// One UR.resolve() call against one RPC at a pinned block hash. Maps the
    /// outcome onto .data/.notFound/.error; never throws. .notFound distinguishes
    /// "resolver not registered" (NO_RESOLVER) from any other revert (NO_CONTENTHASH)
    /// because the consensus algorithm buckets them separately — conflating them
    /// lets a transient CCIP gateway failure combine with a real NO_RESOLVER to
    /// forge a "verified not-found".
    static func run(
        url: URL,
        dnsEncodedName: Data,
        callData: Data,
        blockHash: String,
        timeout: TimeInterval
    ) async -> Outcome {
        do {
            let urCall = try abiEncodeResolve(name: dnsEncodedName, callData: callData)
            let hex = try await ethCallAtBlockHash(
                rpcURL: url,
                to: ENSResolver.universalResolverAddress.asString(),
                dataHex: urCall.web3.hexString,
                blockHash: blockHash,
                timeout: timeout
            )
            let (data, resolver) = try abiDecodeResolveResponse(hex)
            return .init(url: url, kind: .data(resolvedData: data, resolverAddress: resolver))
        } catch let RPCError.executionRevert(revertData) {
            let isNoResolver = revertData
                .flatMap(revertSelector)
                .map(resolverNotFoundSelectors.contains) ?? false
            return .init(url: url, kind: .notFound(reason: isNoResolver ? .noResolver : .noContenthash))
        } catch {
            return .init(url: url, kind: .error(error))
        }
    }

    // UR custom-error selectors (first 4 bytes of keccak256(signature)).
    // https://docs.ens.domains/resolvers/universal/
    private static let resolverNotFoundSelectors: Set<String> = [
        "0x77209fe8",  // ResolverNotFound(bytes)
        "0x1e9535f2",  // ResolverNotContract(bytes,address)
    ]

    // MARK: ABI

    private static func abiEncodeResolve(name: Data, callData: Data) throws -> Data {
        let encoder = ABIFunctionEncoder("resolve")
        try encoder.encode(name)
        try encoder.encode(callData)
        return try encoder.encoded()
    }

    private static func abiDecodeResolveResponse(_ hex: String) throws -> (Data, EthereumAddress) {
        let decoded = try ABIDecoder.decodeData(hex, types: [Data.self, EthereumAddress.self])
        let data: Data = try decoded[0].decoded()
        let resolver: EthereumAddress = try decoded[1].decoded()
        return (data, resolver)
    }

    private static func revertSelector(_ hex: String) -> String? {
        guard hex.hasPrefix("0x"), hex.count >= 10 else { return nil }
        return String(hex.prefix(10)).lowercased()
    }

    // MARK: JSON-RPC transport

    // Dedicated URLSession so browser page loads via URLSession.shared don't
    // contend with RPC legs for the global connection pool, and (more importantly)
    // the per-request timeout below actually bites — on URLSession.shared,
    // request.timeoutInterval is capped at max(request, session.timeoutIntervalForRequest),
    // silently ignoring our 5s setting in favor of the 60s default.
    private static let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    /// eth_call with EIP-1898 blockHash pinning. web3.swift's EthereumBlock
    /// only supports number/tag form; anchor corroboration needs hash pinning
    /// (so a lying provider can't quietly steer the query to stale state), so
    /// we skip the library's client and do the JSON-RPC call directly here.
    private static func ethCallAtBlockHash(
        rpcURL: URL,
        to: String,
        dataHex: String,
        blockHash: String,
        timeout: TimeInterval
    ) async throws -> String {
        let body = EthCallBody(id: 1, callTo: to, callData: dataHex, blockHash: blockHash)
        var req = URLRequest(url: rpcURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await withTimeout(seconds: timeout) {
            try await urlSession.data(for: req)
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw RPCError.httpStatus(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(EthCallResponse.self, from: data)
        if let err = decoded.error {
            // A populated `data` field is the canonical EIP-474/1474 signal
            // for an execution revert — geth/erigon/anvil all set it when a
            // call reverts with return data. Missing it ⇒ non-execution error.
            if err.data != nil {
                throw RPCError.executionRevert(data: err.data)
            }
            throw RPCError.jsonRpc(code: err.code, message: err.message)
        }
        guard let result = decoded.result, !result.isEmpty else {
            throw RPCError.emptyResponse
        }
        return result
    }

    // Task-group timeout: first result wins, the loser gets cancelled.
    // Bullet-proof vs relying on URLRequest/URLSession timeout semantics.
    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ work: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw URLError(.cancelled)
            }
            return first
        }
    }
}

enum RPCError: Error {
    case httpStatus(Int)
    case jsonRpc(code: Int, message: String)
    case executionRevert(data: String?)
    case emptyResponse
}

private struct EthCallBody: Encodable {
    let id: Int
    let callTo: String
    let callData: String
    let blockHash: String

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: OuterKeys.self)
        try c.encode("2.0", forKey: .jsonrpc)
        try c.encode(id, forKey: .id)
        try c.encode("eth_call", forKey: .method)
        var params = c.nestedUnkeyedContainer(forKey: .params)
        try params.encode(CallObject(to: callTo, data: callData))
        try params.encode(BlockObject(blockHash: blockHash))
    }

    private enum OuterKeys: String, CodingKey { case jsonrpc, id, method, params }
    private struct CallObject: Encodable { let to: String; let data: String }
    private struct BlockObject: Encodable { let blockHash: String }
}

private struct EthCallResponse: Decodable {
    struct ErrorBody: Decodable {
        let code: Int
        let message: String
        let data: String?
    }
    let result: String?
    let error: ErrorBody?
}
