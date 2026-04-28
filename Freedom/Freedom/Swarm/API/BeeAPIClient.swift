import Foundation

/// Thin HTTP client for the embedded Bee node's REST API on
/// `127.0.0.1:1633`. Reads only — writes (publish, feeds) live behind the
/// EIP-1193-style permission model in WP4-6.
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
        let data = try await getData(path)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw Error.malformedResponse
        }
        return dict
    }

    private func getData(_ path: String) async throws -> Data {
        let url = Self.baseURL.appendingPathComponent(path)
        do {
            let (data, response) = try await session.data(from: url)
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
}
