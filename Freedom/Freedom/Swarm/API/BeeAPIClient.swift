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
        let (data, _) = try await sendData(path: path, method: "GET", timeout: 60)
        return try Self.parseDict(data)
    }

    /// `GET /feeds/{owner}/{topic}` with optional `?index=...`. Returns
    /// the SOC payload bytes plus the bee-supplied feed-index headers
    /// (16-char hex; `Swarm-Feed-Index-Next` only present on
    /// latest-update reads, never on a specific-index read). 404 maps to
    /// `Error.notFound`; `cannotConnectToHost` etc. propagate as
    /// `Error.notRunning` — both are translated to SWIP wire reasons by
    /// the router.
    func getFeedPayload(
        owner: String, topic: String, index: UInt64? = nil
    ) async throws -> FeedReadResult {
        let path = "/feeds/\(owner)/\(topic)"
        // Bee encodes the FeedIndex (`bytes(8)`) as 16-char zero-padded
        // lowercase hex. `%016x` produces exactly that.
        let query: [String: String] = index.map { ["index": String(format: "%016x", $0)] } ?? [:]
        let (data, headers) = try await sendData(
            path: path, query: query, method: "GET", timeout: 60
        )
        guard let indexHex = headers["swarm-feed-index"],
              let parsedIndex = UInt64(indexHex, radix: 16) else {
            throw Error.malformedResponse
        }
        let nextIndex = headers["swarm-feed-index-next"].flatMap { UInt64($0, radix: 16) }
        return FeedReadResult(payload: data, index: parsedIndex, nextIndex: nextIndex)
    }

    struct FeedReadResult: Equatable {
        let payload: Data
        let index: UInt64
        let nextIndex: UInt64?
    }

    /// `GET /tags/{uid}` — bee's per-upload progress shape. The bridge
    /// rejects 404 (and `notFound` propagates to the SWIP-required
    /// `4100` response) before this typed parser runs, so a successful
    /// return implies bee found the tag.
    func getTag(uid: Int) async throws -> TagResponse {
        let dict = try await getJSON("/tags/\(uid)")
        guard let parsedUid = Self.intFromAnyJSON(dict["uid"]),
              let split = Self.intFromAnyJSON(dict["split"]),
              let seen = Self.intFromAnyJSON(dict["seen"]),
              let stored = Self.intFromAnyJSON(dict["stored"]),
              let sent = Self.intFromAnyJSON(dict["sent"]),
              let synced = Self.intFromAnyJSON(dict["synced"]) else {
            throw Error.malformedResponse
        }
        return TagResponse(
            uid: parsedUid, split: split, seen: seen,
            stored: stored, sent: sent, synced: synced
        )
    }

    struct TagResponse: Equatable {
        let uid: Int
        /// Total chunks the upload split into. `0` is briefly visible
        /// right after tag creation, before bee has chunked the payload —
        /// the derived properties below guard for it.
        let split: Int
        /// Chunks bee has seen (i.e. received from the upload stream).
        let seen: Int
        /// Chunks stored locally on this bee node.
        let stored: Int
        /// Chunks dispatched onto the network. Bee can briefly report
        /// `sent > split` if it counts retries; `progressPercent`
        /// clamps at 100 so dapps' progress bars don't overshoot.
        let sent: Int
        /// Chunks confirmed synced (other peers acknowledged storage).
        let synced: Int

        /// SWIP §"swarm_getUploadStatus" `progress` — `sent / split * 100`,
        /// clamped at `100`, `0` when bee hasn't chunked yet.
        var progressPercent: Int {
            guard split > 0 else { return 0 }
            return min(100, Int(Double(sent) / Double(split) * 100))
        }

        /// SWIP §"swarm_getUploadStatus" `done` — `true` once every
        /// chunk has been dispatched. The `split > 0` guard catches
        /// the brief post-creation window where both fields are zero.
        var isDone: Bool {
            split > 0 && sent >= split
        }
    }

    /// `POST` with no body, used for path-encoded operations
    /// (`/stamps/{amount}/{depth}`), query-encoded ones
    /// (`/chequebook/deposit?amount=...`), and header-encoded ones
    /// (`/feeds/{owner}/{topic}` with `Swarm-Postage-Batch-Id`). Bee's
    /// chain-tx endpoints block on confirmation, which can take ~30s
    /// to several minutes — caller passes a generous timeout.
    func postJSON(
        _ path: String,
        headers: [String: String] = [:],
        query: [String: String] = [:],
        timeout: TimeInterval = 300
    ) async throws -> [String: Any] {
        let (data, _) = try await sendData(
            path: path, query: query, method: "POST",
            headers: headers, timeout: timeout
        )
        return try Self.parseDict(data)
    }

    /// `POST /feeds/{owner}/{topic}` — creates a feed manifest. Returns
    /// the 64-char hex reference of the manifest chunk; bee derives
    /// `bzz://<reference>/` as the stable feed URL. SWIP §"swarm_createFeed"
    /// — idempotent at the bee level (re-creating with the same
    /// `(owner, topic)` returns the existing reference).
    func createFeedManifest(
        owner: String, topic: String, batchID: String
    ) async throws -> String {
        let dict = try await postJSON(
            "/feeds/\(owner)/\(topic)",
            headers: ["Swarm-Postage-Batch-Id": batchID, "Swarm-Pin": "true"]
        )
        guard let reference = dict["reference"] as? String, !reference.isEmpty else {
            throw Error.malformedResponse
        }
        return reference
    }

    /// `POST /bytes` — uploads raw bytes (any size; bee fans out into a
    /// BMT tree internally). Returns the 64-char hex reference of the
    /// root chunk. Used by the `swarm_writeFeedEntry` wrap path for
    /// payloads > 4 KB: upload, fetch the root chunk via `getChunk`,
    /// wrap the resulting CAC into the SOC envelope.
    func uploadBytes(_ payload: Data, batchID: String) async throws -> String {
        let (data, _) = try await postBytes(
            "/bytes",
            body: payload,
            contentType: "application/octet-stream",
            headers: [
                "Swarm-Postage-Batch-Id": batchID,
                "Swarm-Pin": "true",
                "Swarm-Deferred-Upload": "true",
            ]
        )
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reference = dict["reference"] as? String,
              !reference.isEmpty else {
            throw Error.malformedResponse
        }
        return reference
    }

    /// `GET /chunks/{reference}` — fetches the raw chunk bytes
    /// (`span_8 || payload`). For the wrap path: split + rebuild the
    /// CAC so the SOC envelope wraps that root chunk.
    func getChunk(reference: String) async throws -> Data {
        let (data, _) = try await sendData(
            path: "/chunks/\(reference)",
            method: "GET", timeout: 60
        )
        return data
    }

    /// `GET /bytes/{reference}` — bee walks the BMT tree from the
    /// root reference and returns the original byte stream. Used by
    /// `swarm_readFeedEntry` for entries written via the > 4 KB wrap
    /// path: the SOC stores tree references, not the original bytes,
    /// so reads have to re-resolve through this endpoint.
    func downloadBytes(reference: String) async throws -> Data {
        let (data, _) = try await sendData(
            path: "/bytes/\(reference)",
            method: "GET", timeout: 60
        )
        return data
    }

    /// `POST /soc/{owner}/{identifier}?sig=<sig_hex>` — uploads a
    /// Single Owner Chunk. Body is `span_8 || payload`. Bee verifies
    /// SOC ownership by recovering the public key from the signature
    /// + the chunk's content-addressed digest. Returns the SOC's
    /// reference + the upload tag UID. Same `Swarm-Pin` /
    /// `Swarm-Deferred-Upload` headers as the publish path so chunks
    /// don't GC and bee returns the tag immediately.
    func postSOC(
        owner: String, identifier: String, sig: String,
        body: Data, batchID: String
    ) async throws -> (reference: String, tagUid: Int?) {
        let (data, responseHeaders) = try await postBytes(
            "/soc/\(owner)/\(identifier)",
            body: body,
            contentType: "application/octet-stream",
            headers: [
                "Swarm-Postage-Batch-Id": batchID,
                "Swarm-Pin": "true",
                "Swarm-Deferred-Upload": "true",
            ],
            query: ["sig": sig]
        )
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reference = dict["reference"] as? String,
              !reference.isEmpty else {
            throw Error.malformedResponse
        }
        let tagUid = responseHeaders["swarm-tag"].flatMap { Int($0) }
        return (reference, tagUid)
    }

    /// `POST` with a binary body — `swarm_publishData` (raw payload) and
    /// `swarm_publishFiles` (tar collection). Caller supplies
    /// `Content-Type` plus any bee-specific headers
    /// (`Swarm-Postage-Batch-Id`, `Swarm-Collection`,
    /// `Swarm-Index-Document`, …); we return the raw body + headers so
    /// the publish-service can pull the JSON `reference` out of the body
    /// and the `swarm-tag` out of the headers. `contentType:` wins over
    /// any `Content-Type` in `headers`.
    func postBytes(
        _ path: String,
        body: Data,
        contentType: String,
        headers: [String: String] = [:],
        query: [String: String] = [:],
        timeout: TimeInterval = 300
    ) async throws -> (Data, [String: String]) {
        var allHeaders = headers
        allHeaders["Content-Type"] = contentType
        return try await sendData(
            path: path, query: query, method: "POST",
            headers: allHeaders, body: body, timeout: timeout
        )
    }

    /// Returns response data plus headers (lowercased keys for case-
    /// insensitive lookup). Header access is needed by `getFeedPayload`
    /// which carries indices in `Swarm-Feed-Index` / `…-Next`; JSON
    /// callers ignore the second tuple value.
    private func sendData(
        path: String,
        query: [String: String] = [:],
        method: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval
    ) async throws -> (Data, [String: String]) {
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
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // For binary uploads (`postBytes`) `upload(for:from:)` streams
        // the body to bee instead of buffering it inside `URLRequest`,
        // which keeps publish-50 MB peaks off the heap.
        // `data(for:)` stays on the bodyless path.
        do {
            let (data, response): (Data, URLResponse)
            if let body {
                (data, response) = try await session.upload(for: request, from: body)
            } else {
                (data, response) = try await session.data(for: request)
            }
            guard let http = response as? HTTPURLResponse else {
                throw Error.malformedResponse
            }
            switch http.statusCode {
            case 200..<300:
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    if let k = key as? String, let v = value as? String {
                        headers[k.lowercased()] = v
                    }
                }
                return (data, headers)
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
