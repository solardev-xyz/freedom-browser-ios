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

    let createFeedManifest: CreateManifest
    let readFeed: ReadFeed
    let uploadSOC: UploadSOC

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
            }
        )
    }

    enum FeedServiceError: Swift.Error, Equatable {
        case unreachable
        case malformedResponse
        case other(String)
    }

    struct CreateFeedResult: Equatable {
        let topic: String
        let ownerHex: String
        let manifestReference: String
        let bzzUrl: String
    }

    struct UpdateFeedResult: Equatable {
        let index: UInt64
        let socReference: String
        let tagUid: Int?
    }

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
        let upload = try await signAndUploadSOC(
            ownerHex: ownerHex, topicBytes: topicBytes, index: nextIndex,
            socPayload: socPayload, privateKey: privateKey, batchID: batchID
        )
        return UpdateFeedResult(
            index: nextIndex,
            socReference: upload.reference,
            tagUid: upload.tagUid
        )
    }

    /// Builds the SOC envelope (CAC over `socPayload`, identifier from
    /// `topic || indexBE`), signs `keccak256(identifier || cac.address)`
    /// under EIP-191, and POSTs to bee. Reused by `swarm_writeFeedEntry`
    /// at WP6.4 — same SOC primitive, different payload composition.
    private func signAndUploadSOC(
        ownerHex: String, topicBytes: Data, index: UInt64,
        socPayload: Data, privateKey: Data, batchID: String
    ) async throws -> (reference: String, tagUid: Int?) {
        let identifier = SwarmSOC.feedIdentifier(topic: topicBytes, index: index)
        let cac: SwarmSOC.CAC
        do {
            cac = try SwarmSOC.makeCAC(payload: socPayload)
        } catch {
            throw FeedServiceError.other("cac: \(error)")
        }
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
