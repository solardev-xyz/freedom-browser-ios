import Foundation

/// Upload + response-parse helpers for `swarm_publishData` (now) and
/// `swarm_publishFiles` (WP5.3). The transport call comes in via a
/// closure rather than a `BeeAPIClient` reference — keeps the type
/// SwiftData-/URLSession-free so unit tests can stub the upload without
/// `URLProtocol` mocking.
@MainActor
struct SwarmPublishService {
    /// `(path, body, contentType, headers, query) → (responseData, responseHeaders)`.
    /// Production wires through `BeeAPIClient.postBytes`; tests stub
    /// directly. Throws `BeeAPIClient.Error.*` shapes the implementation
    /// recognises and remaps below.
    typealias Upload = @MainActor (
        _ path: String,
        _ body: Data,
        _ contentType: String,
        _ headers: [String: String],
        _ query: [String: String]
    ) async throws -> (Data, [String: String])

    let upload: Upload

    /// Production constructor. Captures `bee` by value (struct).
    static func live(bee: BeeAPIClient) -> Self {
        Self(upload: { path, body, contentType, headers, query in
            try await bee.postBytes(
                path, body: body, contentType: contentType,
                headers: headers, query: query
            )
        })
    }

    struct UploadResult: Equatable {
        /// 64-char hex Swarm reference of the uploaded content.
        let reference: String
        /// Bee's `swarm-tag` response header — the upload-progress tag UID
        /// `swarm_getUploadStatus` queries against (WP5.4). Optional;
        /// some bee versions omit it for raw single-file uploads.
        let tagUid: Int?
    }

    enum PublishError: Swift.Error, Equatable {
        /// `BeeAPIClient.Error.notRunning` — bridge maps to 4900
        /// `node-stopped`.
        case unreachable
        /// 200 from bee but body wasn't `{"reference": "<hex>"}`.
        case malformedResponse
        /// Any other bee-side / transport failure. Bridge maps to -32603.
        case other(String)
    }

    /// Bee `POST /bzz` for a single payload. Returns the 64-char
    /// reference + optional tag UID; throws `PublishError` for the
    /// bridge to translate into a SWIP wire-format error.
    ///
    /// `Swarm-Pin: true` is mandatory per SWIP §"swarm_publishData
    /// behavior" — without it, bee may garbage-collect the chunks.
    /// `Swarm-Deferred-Upload: true` makes bee return immediately
    /// with the reference + a tag UID and dispatch to the network
    /// asynchronously (otherwise the response blocks until every
    /// chunk is sent — slower, and bee may not return a tag at all).
    func publishData(
        _ data: Data,
        contentType: String,
        name: String?,
        batchID: String
    ) async throws -> UploadResult {
        var query: [String: String] = [:]
        if let name, !name.isEmpty { query["name"] = name }
        return try await postUpload(
            body: data, contentType: contentType,
            extraHeaders: [:], query: query, batchID: batchID
        )
    }

    /// Bee `POST /bzz` for a USTAR tar archive. `Swarm-Collection: true`
    /// tells bee to parse the tar and emit a manifest pointing at each
    /// entry; `Swarm-Index-Document: <path>` (when set) marks the
    /// default file served from the manifest's root URL.
    func publishFiles(
        _ tarBytes: Data,
        indexDocument: String?,
        batchID: String
    ) async throws -> UploadResult {
        var headers: [String: String] = ["Swarm-Collection": "true"]
        if let indexDocument {
            headers["Swarm-Index-Document"] = indexDocument
        }
        return try await postUpload(
            body: tarBytes, contentType: "application/x-tar",
            extraHeaders: headers, query: [:], batchID: batchID
        )
    }

    private func postUpload(
        body: Data, contentType: String,
        extraHeaders: [String: String],
        query: [String: String],
        batchID: String
    ) async throws -> UploadResult {
        var headers: [String: String] = [
            "Swarm-Postage-Batch-Id": batchID,
            "Swarm-Pin": "true",
            "Swarm-Deferred-Upload": "true",
        ]
        headers.merge(extraHeaders) { _, new in new }
        let responseData: Data
        let responseHeaders: [String: String]
        do {
            (responseData, responseHeaders) = try await upload(
                "/bzz", body, contentType, headers, query
            )
        } catch BeeAPIClient.Error.notRunning {
            throw PublishError.unreachable
        } catch {
            throw PublishError.other("\(error)")
        }
        return try Self.parseUploadResponse(
            data: responseData, headers: responseHeaders
        )
    }

    private static func parseUploadResponse(
        data: Data, headers: [String: String]
    ) throws -> UploadResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reference = json["reference"] as? String,
              !reference.isEmpty else {
            throw PublishError.malformedResponse
        }
        let tagUid = headers["swarm-tag"].flatMap { Int($0) }
        return UploadResult(reference: reference, tagUid: tagUid)
    }
}
