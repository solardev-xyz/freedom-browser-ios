import Foundation
import web3

/// Bee-side writes for the SWIP chunk tier (`swarm_publishChunk`,
/// `swarm_writeSingleOwnerChunk`). Mirrors `SwarmFeedService`'s
/// closure-injection so unit tests stub the bee calls without
/// `URLProtocol` mocking. Reads have no service — the router fetches
/// raw chunk bytes through its own injected closure and validates via
/// `SwarmChunkCodec`.
@MainActor
struct SwarmChunkService {
    typealias UploadChunk = @MainActor (
        _ body: Data, _ batchID: String
    ) async throws -> (reference: String, tagUid: Int?)

    let uploadChunk: UploadChunk
    let uploadSOC: SwarmFeedService.UploadSOC

    static func live(bee: BeeAPIClient) -> Self {
        Self(
            uploadChunk: { body, batchID in
                try await bee.postChunk(body: body, batchID: batchID)
            },
            uploadSOC: { owner, identifier, sig, body, batchID in
                try await bee.postSOC(
                    owner: owner, identifier: identifier, sig: sig,
                    body: body, batchID: batchID
                )
            }
        )
    }

    enum ChunkServiceError: Swift.Error, Equatable {
        case unreachable
        case other(String)
    }

    struct ChunkWriteResult: Equatable {
        let reference: String
        let tagUid: Int?
    }

    /// SWIP §"swarm_publishChunk" — CAC upload. Body sent to bee is
    /// `span_8LE || payload`; the explicit `span` override exists for
    /// intermediate nodes of caller-built BMT trees and defaults to
    /// the payload length.
    func publishChunk(
        payload: Data, span: UInt64?, batchID: String
    ) async throws -> ChunkWriteResult {
        let cac = try makeCAC(payload: payload, span: span)
        do {
            let result = try await uploadChunk(SwarmSOC.socBody(cac: cac), batchID)
            return ChunkWriteResult(reference: result.reference, tagUid: result.tagUid)
        } catch BeeAPIClient.Error.notRunning {
            throw ChunkServiceError.unreachable
        } catch {
            throw ChunkServiceError.other("uploadChunk: \(error)")
        }
    }

    struct SOCWriteResult: Equatable {
        let reference: String
        /// Unprefixed lowercase 40-hex — bee's URL-path form. Bridge
        /// checksums for the dapp-visible reply.
        let ownerHex: String
        let tagUid: Int?
    }

    /// SWIP §"swarm_writeSingleOwnerChunk" — SOC at a caller-chosen
    /// 32-byte identifier, signed with the origin's feed identity.
    /// Same crypto as the feed-entry path (`SwarmFeedService`); only
    /// the identifier derivation differs (caller-supplied instead of
    /// `keccak256(topic || indexBE)`).
    func writeSingleOwnerChunk(
        identifier: Data, payload: Data, span: UInt64?,
        privateKey: Data, batchID: String
    ) async throws -> SOCWriteResult {
        precondition(identifier.count == 32, "identifier must be 32 bytes")
        let cac = try makeCAC(payload: payload, span: span)
        let ownerHex: String
        do {
            ownerHex = try FeedSigner.ownerAddressBytes(privateKey: privateKey)
                .web3.hexString.web3.noHexPrefix
        } catch {
            throw ChunkServiceError.other("owner: \(error)")
        }
        let digest = SwarmSOC.signingMessage(
            identifier: identifier, cacAddress: cac.address
        ).web3.keccak256
        let sig: Data
        do {
            sig = try FeedSigner.sign(digest: digest, privateKey: privateKey)
        } catch {
            throw ChunkServiceError.other("sign: \(error)")
        }
        do {
            let result = try await uploadSOC(
                ownerHex,
                identifier.web3.hexString.web3.noHexPrefix,
                sig.web3.hexString.web3.noHexPrefix,
                SwarmSOC.socBody(cac: cac),
                batchID
            )
            return SOCWriteResult(
                reference: result.reference, ownerHex: ownerHex,
                tagUid: result.tagUid
            )
        } catch BeeAPIClient.Error.notRunning {
            throw ChunkServiceError.unreachable
        } catch {
            throw ChunkServiceError.other("uploadSOC: \(error)")
        }
    }

    private func makeCAC(payload: Data, span: UInt64?) throws -> SwarmSOC.CAC {
        do {
            if let span {
                return try SwarmSOC.makeCAC(
                    span: SwarmChunkCodec.spanBytes(span), payload: payload
                )
            }
            return try SwarmSOC.makeCAC(payload: payload)
        } catch {
            throw ChunkServiceError.other("cac: \(error)")
        }
    }
}
