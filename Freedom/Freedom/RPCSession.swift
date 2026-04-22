import Foundation

enum RPCSession {
    // Dedicated session so browser page loads via URLSession.shared don't
    // contend with RPC legs for the global connection pool, and (more
    // importantly) our per-call timeout actually bites — URLSession.shared
    // caps the effective timeout at max(request, session default 60s),
    // silently ignoring shorter per-request values.
    static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    struct Response<R: Decodable>: Decodable {
        struct ErrorBody: Decodable {
            let code: Int
            let message: String
            // Populated by geth/erigon/anvil when a call reverts with return
            // data (EIP-474/1474). Its presence is the eth_call layer's
            // revert vs. plain-RPC-error discriminator.
            let data: String?
        }
        let result: R?
        let error: ErrorBody?
    }

    /// JSON-RPC POST with task-group-based timeout. Caller interprets
    /// Response.error per its needs — revert-vs-error distinctions live
    /// at call sites, not here.
    static func post<Body: Encodable, R: Decodable>(
        url: URL,
        body: Body,
        timeout: TimeInterval
    ) async throws -> Response<R> {
        var builder = URLRequest(url: url)
        builder.httpMethod = "POST"
        builder.setValue("application/json", forHTTPHeaderField: "Content-Type")
        builder.httpBody = try encoder.encode(body)
        let req = builder

        let (data, response) = try await withTimeout(seconds: timeout) {
            try await shared.data(for: req)
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw RPCError.httpStatus(http.statusCode)
        }
        return try decoder.decode(Response<R>.self, from: data)
    }

    /// Bullet-proof per-call timeout via Task-group race: whichever of
    /// `work` and a sleep-and-throw task finishes first wins, the other
    /// gets cancelled. Avoids URLRequest/URLSession timeout gotchas.
    static func withTimeout<T: Sendable>(
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

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
