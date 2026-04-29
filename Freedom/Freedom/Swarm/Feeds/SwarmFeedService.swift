import Foundation
import web3

/// Bee-side feed operations. Closure-injected so unit tests stub the
/// bee calls without `URLProtocol` mocking.
@MainActor
struct SwarmFeedService {
    typealias CreateManifest = @MainActor (
        _ owner: String, _ topic: String, _ batchID: String
    ) async throws -> String

    typealias ReadFeed = @MainActor (
        _ owner: String, _ topic: String, _ index: UInt64?
    ) async throws -> BeeAPIClient.FeedReadResult

    typealias UploadSOC = @MainActor (
        _ owner: String, _ identifier: String, _ sig: String,
        _ body: Data, _ batchID: String
    ) async throws -> (reference: String, tagUid: Int?)

    /// `(payload, batchID) → root reference`. Used by `writeFeedEntry`'s
    /// wrap path for payloads > 4 KB.
    typealias UploadBytes = @MainActor (
        _ payload: Data, _ batchID: String
    ) async throws -> String

    /// `(reference) → raw chunk bytes (span_8 || payload)`. Used by
    /// `writeFeedEntry`'s wrap path to fetch the root chunk for SOC
    /// wrapping.
    typealias GetChunk = @MainActor (_ reference: String) async throws -> Data

    let createFeedManifest: CreateManifest
    let readFeed: ReadFeed
    let uploadSOC: UploadSOC
    let uploadBytes: UploadBytes
    let getChunk: GetChunk

    static func live(bee: BeeAPIClient) -> Self {
        Self(
            createFeedManifest: { owner, topic, batchID in
                try await bee.createFeedManifest(
                    owner: owner, topic: topic, batchID: batchID
                )
            },
            readFeed: { owner, topic, index in
                try await bee.getFeedPayload(
                    owner: owner, topic: topic, index: index
                )
            },
            uploadSOC: { owner, identifier, sig, body, batchID in
                try await bee.postSOC(
                    owner: owner, identifier: identifier, sig: sig,
                    body: body, batchID: batchID
                )
            },
            uploadBytes: { payload, batchID in
                try await bee.uploadBytes(payload, batchID: batchID)
            },
            getChunk: { reference in
                try await bee.getChunk(reference: reference)
            }
        )
    }

    enum FeedServiceError: Swift.Error, Equatable {
        case unreachable
        case malformedResponse
        /// SWIP §"swarm_writeFeedEntry" — explicit-index write where an
        /// entry already exists. Bridge maps to `-32602` with
        /// `data.reason = "index_already_exists"`.
        case indexAlreadyExists(index: UInt64)
        case other(String)
    }

    struct CreateFeedResult: Equatable {
        let topic: String
        let ownerHex: String
        let manifestReference: String
        let bzzUrl: String
    }

    /// Both `updateFeed` and `writeFeedEntry` return the same shape
    /// from bee — the resolved index plus the SOC reference + upload
    /// tag. Aliased per-method-name so call sites read intent.
    struct FeedWriteResult: Equatable {
        let index: UInt64
        let socReference: String
        let tagUid: Int?
    }

    typealias UpdateFeedResult = FeedWriteResult
    typealias WriteFeedEntryResult = FeedWriteResult

    func createFeed(
        ownerHex: String, topicHex: String, batchID: String
    ) async throws -> CreateFeedResult {
        do {
            let reference = try await createFeedManifest(ownerHex, topicHex, batchID)
            return CreateFeedResult(
                topic: topicHex,
                ownerHex: ownerHex,
                manifestReference: reference,
                bzzUrl: "bzz://\(reference)"
            )
        } catch BeeAPIClient.Error.notRunning {
            throw FeedServiceError.unreachable
        } catch BeeAPIClient.Error.malformedResponse {
            throw FeedServiceError.malformedResponse
        } catch {
            throw FeedServiceError.other("\(error)")
        }
    }

    /// SOC payload is `timestamp_8BE || contentReference_32`,
    /// matching bee-js's `updateFeedWithReference`. Index is resolved
    /// from the latest feed read (or 0 if the feed is empty); bridge
    /// wraps the call in `SwarmFeedWriteLock` so concurrent writes
    /// don't race to the same index.
    func updateFeed(
        ownerHex: String, topicHex: String,
        contentReference: String,
        privateKey: Data,
        batchID: String
    ) async throws -> UpdateFeedResult {
        guard let topicBytes = Data(hex: topicHex), topicBytes.count == 32 else {
            throw FeedServiceError.other("topicHex must be 32-byte hex")
        }
        guard let referenceBytes = Data(hex: contentReference),
              referenceBytes.count == 32 else {
            throw FeedServiceError.other("contentReference must be 32-byte hex")
        }
        let nextIndex = try await resolveNextIndex(
            ownerHex: ownerHex, topicHex: topicHex
        )
        let socPayload = Self.timestampBytes() + referenceBytes
        let cac: SwarmSOC.CAC
        do {
            cac = try SwarmSOC.makeCAC(payload: socPayload)
        } catch {
            throw FeedServiceError.other("cac: \(error)")
        }
        let upload = try await signAndUploadSOC(
            ownerHex: ownerHex, topicBytes: topicBytes, index: nextIndex,
            cac: cac, privateKey: privateKey, batchID: batchID
        )
        return UpdateFeedResult(
            index: nextIndex,
            socReference: upload.reference,
            tagUid: upload.tagUid
        )
    }

    /// SWIP §"swarm_writeFeedEntry" journal pattern. Payloads > 4 KB
    /// route through `wrapLargePayload`; explicit-index writes probe
    /// for collision before signing. Atomicity (probe + write) is the
    /// bridge's `SwarmFeedWriteLock` concern.
    func writeFeedEntry(
        ownerHex: String, topicHex: String,
        payload: Data,
        explicitIndex: UInt64?,
        privateKey: Data,
        batchID: String
    ) async throws -> WriteFeedEntryResult {
        guard let topicBytes = Data(hex: topicHex), topicBytes.count == 32 else {
            throw FeedServiceError.other("topicHex must be 32-byte hex")
        }
        guard !payload.isEmpty else {
            throw FeedServiceError.other("payload must not be empty")
        }

        let writeIndex: UInt64
        if let explicitIndex {
            try await assertIndexAvailable(
                ownerHex: ownerHex, topicHex: topicHex, index: explicitIndex
            )
            writeIndex = explicitIndex
        } else {
            writeIndex = try await resolveNextIndex(
                ownerHex: ownerHex, topicHex: topicHex
            )
        }

        // For payloads <= 4 KB the SOC's CAC is built directly over
        // the payload bytes. For larger payloads bee's `/bytes` fans
        // them into a BMT tree; we wrap the resulting root chunk so
        // the SOC points at the tree root, and bee resolves children
        // through the bzz hash chain on read.
        let socCAC: SwarmSOC.CAC
        if payload.count <= SwarmSOC.maxChunkPayloadSize {
            do {
                socCAC = try SwarmSOC.makeCAC(payload: payload)
            } catch {
                throw FeedServiceError.other("cac: \(error)")
            }
        } else {
            socCAC = try await wrapLargePayload(payload: payload, batchID: batchID)
        }

        let upload = try await signAndUploadSOC(
            ownerHex: ownerHex, topicBytes: topicBytes, index: writeIndex,
            cac: socCAC, privateKey: privateKey, batchID: batchID
        )
        return WriteFeedEntryResult(
            index: writeIndex,
            socReference: upload.reference,
            tagUid: upload.tagUid
        )
    }

    /// Probes bee for an entry at exactly `index`. SWIP-required
    /// overwrite protection.
    ///
    /// Uses `/chunks/{socAddress}` rather than `/feeds/{owner}/{topic}?index=N`:
    /// the feeds endpoint does epoch-based "at-or-before" lookup
    /// (returns the latest entry below the requested index when the
    /// exact slot is empty), which would falsely flag every probe
    /// after index 0 as occupied. The SOC address path is exact-match.
    private func assertIndexAvailable(
        ownerHex: String, topicHex: String, index: UInt64
    ) async throws {
        guard let topicBytes = Data(hex: topicHex), topicBytes.count == 32 else {
            throw FeedServiceError.other("topicHex must be 32-byte hex")
        }
        guard let ownerBytes = Data(hex: ownerHex), ownerBytes.count == 20 else {
            throw FeedServiceError.other("ownerHex must be 20-byte hex")
        }
        let identifier = SwarmSOC.feedIdentifier(topic: topicBytes, index: index)
        let socAddressHex = SwarmSOC.socAddress(
            identifier: identifier, ownerAddress: ownerBytes
        ).web3.hexString.web3.noHexPrefix
        do {
            _ = try await getChunk(socAddressHex)
            throw FeedServiceError.indexAlreadyExists(index: index)
        } catch BeeAPIClient.Error.notFound {
            // exact-index slot is empty — proceed
        } catch BeeAPIClient.Error.notRunning {
            throw FeedServiceError.unreachable
        }
    }

    /// > 4 KB payload wrap path. Upload via `/bytes`, fetch the root
    /// chunk's raw bytes (`span_8 || payload`), and rebuild a CAC over
    /// that pair. The resulting CAC's address equals the bee-returned
    /// reference, so bee verifies the SOC's content-addressed digest
    /// when we sign + upload.
    private func wrapLargePayload(
        payload: Data, batchID: String
    ) async throws -> SwarmSOC.CAC {
        let reference: String
        do {
            reference = try await uploadBytes(payload, batchID)
        } catch BeeAPIClient.Error.notRunning {
            throw FeedServiceError.unreachable
        } catch {
            throw FeedServiceError.other("uploadBytes: \(error)")
        }

        let chunkBytes: Data
        do {
            chunkBytes = try await getChunk(reference)
        } catch BeeAPIClient.Error.notRunning {
            throw FeedServiceError.unreachable
        } catch {
            throw FeedServiceError.other("getChunk: \(error)")
        }

        guard chunkBytes.count >= 8 else {
            throw FeedServiceError.malformedResponse
        }
        let span = chunkBytes.prefix(8)
        let chunkPayload = chunkBytes.dropFirst(8)
        do {
            return try SwarmSOC.makeCAC(span: Data(span), payload: Data(chunkPayload))
        } catch {
            throw FeedServiceError.other("wrap cac: \(error)")
        }
    }

    /// Signs `keccak256(identifier || cac.address)` under EIP-191 and
    /// POSTs the SOC body to bee. Identifier = `topic || indexBE`.
    private func signAndUploadSOC(
        ownerHex: String, topicBytes: Data, index: UInt64,
        cac: SwarmSOC.CAC, privateKey: Data, batchID: String
    ) async throws -> (reference: String, tagUid: Int?) {
        let identifier = SwarmSOC.feedIdentifier(topic: topicBytes, index: index)
        let digest = SwarmSOC.signingMessage(
            identifier: identifier, cacAddress: cac.address
        ).web3.keccak256
        let sig: Data
        do {
            sig = try FeedSigner.sign(digest: digest, privateKey: privateKey)
        } catch {
            throw FeedServiceError.other("sign: \(error)")
        }
        do {
            return try await uploadSOC(
                ownerHex,
                identifier.web3.hexString.web3.noHexPrefix,
                sig.web3.hexString.web3.noHexPrefix,
                SwarmSOC.socBody(cac: cac),
                batchID
            )
        } catch BeeAPIClient.Error.notRunning {
            throw FeedServiceError.unreachable
        } catch {
            throw FeedServiceError.other("uploadSOC: \(error)")
        }
    }

    /// Latest-update read: bee returns `feedIndexNext` for the next
    /// writable index. Empty feed (bee 404) starts at 0.
    private func resolveNextIndex(
        ownerHex: String, topicHex: String
    ) async throws -> UInt64 {
        do {
            let read = try await readFeed(ownerHex, topicHex, nil)
            return read.nextIndex ?? read.index + 1
        } catch BeeAPIClient.Error.notFound {
            return 0
        } catch BeeAPIClient.Error.notRunning {
            throw FeedServiceError.unreachable
        } catch {
            throw FeedServiceError.other("resolveNextIndex: \(error)")
        }
    }

    private static func timestampBytes() -> Data {
        var t = UInt64(Date().timeIntervalSince1970).bigEndian
        return withUnsafeBytes(of: &t) { Data($0) }
    }
}
