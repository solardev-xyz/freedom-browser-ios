import Foundation
import web3

/// Pure crypto primitives for Single Owner Chunk (SOC) feed writes.
/// Mirrors bee-js's `chunk/cac.js`, `chunk/bmt.js`, `chunk/soc.js`, and
/// `feed/identifier.js` byte-for-byte — pinned by `SwarmSOCTests`
/// against vectors captured from the running bee-js. No I/O, no
/// transport, no signing — `SwarmFeedService` composes these with
/// `FeedSigner` and `BeeAPIClient`.
enum SwarmSOC {
    /// 32-byte segments at the BMT leaves. Bee constant.
    static let segmentSize = 32
    /// 4 KB max payload inside a single chunk. Bee constant — payloads
    /// larger than this are uploaded via `/bytes` and the resulting
    /// root chunk is wrapped into the SOC instead.
    static let maxChunkPayloadSize = 4096

    enum Error: Swift.Error, Equatable {
        case payloadEmpty
        case payloadTooLarge
    }

    /// Identifier for a feed entry: `keccak256(topic_32 || feedIndex_8BE)`.
    /// Bee's feed-update endpoint addresses chunks by this identifier.
    static func feedIdentifier(topic: Data, index: UInt64) -> Data {
        precondition(topic.count == 32, "topic must be 32 bytes")
        var beIndex = index.bigEndian
        let indexBytes = withUnsafeBytes(of: &beIndex) { Data($0) }
        return (topic + indexBytes).web3.keccak256
    }

    /// Span: 8 bytes little-endian of payload length. Bee uses LE here
    /// (despite using BE for the feed index — different fields, different
    /// conventions).
    private static func spanBytes(payloadLength: Int) -> Data {
        var leLength = UInt64(payloadLength).littleEndian
        return withUnsafeBytes(of: &leLength) { Data($0) }
    }

    /// Content-Addressed Chunk. The `address` is what bee uses to look
    /// up the underlying bytes; the SOC envelope wraps `(span, payload)`
    /// at a separately-derived `socAddress` and keeps the same address
    /// for content lookups.
    struct CAC: Equatable {
        let span: Data
        let payload: Data
        let address: Data
    }

    /// Build a CAC for an in-line payload. Throws on empty or > 4096
    /// — the wrap-via-`/bytes` path for larger payloads composes via
    /// `makeCAC(span:payload:)` over the root chunk bee returns from
    /// `/chunks/{ref}`.
    static func makeCAC(payload: Data) throws -> CAC {
        guard !payload.isEmpty else { throw Error.payloadEmpty }
        guard payload.count <= maxChunkPayloadSize else { throw Error.payloadTooLarge }
        let span = spanBytes(payloadLength: payload.count)
        let root = bmtRoot(payload: payload)
        let address = (span + root).web3.keccak256
        return CAC(span: span, payload: payload, address: address)
    }

    /// Build a CAC from an externally-supplied `(span, payload)` pair —
    /// used by the > 4096-byte wrap path. Bee's `GET /chunks/{ref}`
    /// returns `span_8 || encoded-payload` for the root chunk; we
    /// split + rebuild the CAC so the SOC envelope wraps that root.
    /// Same address formula as `makeCAC(payload:)`.
    static func makeCAC(span: Data, payload: Data) throws -> CAC {
        precondition(span.count == 8, "span must be 8 bytes")
        guard !payload.isEmpty else { throw Error.payloadEmpty }
        guard payload.count <= maxChunkPayloadSize else { throw Error.payloadTooLarge }
        let address = (span + bmtRoot(payload: payload)).web3.keccak256
        return CAC(span: span, payload: payload, address: address)
    }

    /// SOC address: `keccak256(identifier_32 || ownerAddress_20)`. Bee
    /// uses this as the chunk's address in /chunks lookups; combined
    /// with the signature recovery, it's how bee verifies SOC ownership.
    static func socAddress(identifier: Data, ownerAddress: Data) -> Data {
        precondition(identifier.count == 32, "identifier must be 32 bytes")
        precondition(ownerAddress.count == 20, "ownerAddress must be 20 bytes")
        return (identifier + ownerAddress).web3.keccak256
    }

    /// HTTP body for `POST /soc/{owner}/{identifier}` — `span || payload`.
    static func socBody(cac: CAC) -> Data {
        cac.span + cac.payload
    }

    /// Bytes the SOC envelope occupies: `identifier(32) || signature(65)
    /// || span(8)`. Bee's `/chunks/{socAddress}` returns this envelope
    /// followed by the payload; readers strip the first 105 bytes to
    /// get the payload back.
    static let socEnvelopeSize = 32 + 65 + 8

    /// Raw 64 bytes signed for SOC ownership: `identifier || cac.address`.
    /// `FeedSigner` wraps this with the EIP-191 `\x19Ethereum Signed
    /// Message:\n32` prefix before hashing — matches bee-js's
    /// `PrivateKey.sign(...)` exactly.
    static func signingMessage(identifier: Data, cacAddress: Data) -> Data {
        precondition(identifier.count == 32, "identifier must be 32 bytes")
        precondition(cacAddress.count == 32, "cacAddress must be 32 bytes")
        return identifier + cacAddress
    }

    // MARK: - BMT

    /// Binary Merkle Tree root over a 4 KB block (zero-padded if shorter).
    private static func bmtRoot(payload: Data) -> Data {
        precondition(payload.count <= maxChunkPayloadSize,
                     "payload exceeds max chunk size")
        var padded = Data(count: maxChunkPayloadSize)
        padded.replaceSubrange(0..<payload.count, with: payload)
        var level = stride(from: 0, to: padded.count, by: segmentSize).map {
            padded.subdata(in: $0..<$0 + segmentSize)
        }
        while level.count > 1 {
            var next: [Data] = []
            next.reserveCapacity(level.count / 2)
            for i in stride(from: 0, to: level.count, by: 2) {
                next.append((level[i] + level[i + 1]).web3.keccak256)
            }
            level = next
        }
        return level[0]
    }
}
