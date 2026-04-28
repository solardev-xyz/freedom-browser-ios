import Foundation

/// Thin HTTP client for the embedded Bee node's REST API on
/// `127.0.0.1:1633`. Reads + a small set of writes the user explicitly
/// triggers (stamp purchase). Dapp-driven writes (publish, feeds) live
/// behind the EIP-1193-style permission model in WP4-6.
struct BeeAPIClient {
    static let baseURL = URL(string: "http://127.0.0.1:1633")!

    enum Error: Swift.Error, Equatable {
        case notRunning           // network refused (bee not up)
        case notFound             // 404
        case transient(Int)       // 5xx, retryable
        case malformedResponse    // body wasn't JSON or missing fields
    }

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Bee endpoints return flat dicts. Wrapper objects (e.g. `/stamps`
    /// returning `{stamps: [...]}`) are handled by the caller casting
    /// the wrapped value out of the dict.
    func getJSON(_ path: String) async throws -> [String: Any] {
        let data = try await sendData(path: path, method: "GET", timeout: 60)
        return try Self.parseDict(data)
    }

    /// `POST` with no body, used for both path-encoded operations
    /// (`/stamps/{amount}/{depth}`) and query-encoded ones
    /// (`/chequebook/deposit?amount=...`). Bee's chain-tx endpoints
    /// block on confirmation, which can take ~30s to several minutes —
    /// caller passes a generous timeout.
    func postJSON(
        _ path: String,
        query: [String: String] = [:],
        timeout: TimeInterval = 300
    ) async throws -> [String: Any] {
        let data = try await sendData(
            path: path, query: query, method: "POST", timeout: timeout
        )
        return try Self.parseDict(data)
    }

    private func sendData(
        path: String,
        query: [String: String] = [:],
        method: String,
        timeout: TimeInterval
    ) async throws -> Data {
        let baseWithPath = Self.baseURL.appendingPathComponent(path)
        guard var components = URLComponents(url: baseWithPath, resolvingAgainstBaseURL: false) else {
            throw Error.malformedResponse
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw Error.malformedResponse }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw Error.malformedResponse
            }
            switch http.statusCode {
            case 200..<300: return data
            case 404: throw Error.notFound
            case 500..<600: throw Error.transient(http.statusCode)
            default: throw Error.malformedResponse
            }
        } catch let error as Error {
            throw error
        } catch let error as URLError where error.code == .cannotConnectToHost
                                           || error.code == .networkConnectionLost {
            throw Error.notRunning
        } catch {
            throw Error.malformedResponse
        }
    }

    private static func parseDict(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw Error.malformedResponse
        }
        return dict
    }

    /// Bee returns numeric fields as either JSON number (most cases) or
    /// string (some legacy/big-int fields) depending on version. Both
    /// shapes route through this helper so callers can pull `Int` out of
    /// `[String: Any]` without per-call duck-typing.
    static func intFromAnyJSON(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let int = value as? Int { return int }
        if let int64 = value as? Int64 { return Int(int64) }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
