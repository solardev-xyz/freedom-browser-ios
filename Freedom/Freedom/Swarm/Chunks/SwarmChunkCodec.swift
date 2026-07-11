import Foundation
import web3

/// Pure parsing + validation for the SWIP chunk tier
/// (`swarm_readChunk` / `swarm_readSingleOwnerChunk`) plus the span
/// helpers the write paths share. Composes `SwarmSOC`'s primitives;
/// no I/O — `SwarmRouter` injects the transport.
///
/// SWIP §"Type validation on read" requires recomputing the
/// type-specific address from the returned bytes: BMT for CACs,
/// signature recovery + `keccak256(identifier || owner)` for SOCs.
/// Bee's `/chunks/{address}` endpoint gives no such guarantee itself
/// (a CAC and a SOC can structurally live at the same address).
enum SwarmChunkCodec {
    enum Error: Swift.Error, Equatable {
        /// Returned bytes don't validate as the requested chunk type —
        /// BMT/address mismatch for CACs; short body, unrecoverable
        /// signature, or derived-address mismatch for SOCs. Bridge/
        /// router map to `-32602` `chunk_type_mismatch`.
        case typeMismatch
    }

    /// `GET /chunks/{reference}` body for a CAC: `span_8LE || payload`.
    /// Validates by rebuilding the CAC and comparing addresses.
    static func parseCAC(
        referenceHex: String, raw: Data
    ) throws -> (span: UInt64, payload: Data) {
        // ≥ 9: span + at least one payload byte. ≤ 8 + 4096: a single
        // chunk can't carry more — anything larger is not a chunk.
        guard raw.count >= 9,
              raw.count <= 8 + SwarmSOC.maxChunkPayloadSize else {
            throw Error.typeMismatch
        }
        let span = Data(raw.prefix(8))
        let payload = Data(raw.dropFirst(8))
        guard let cac = try? SwarmSOC.makeCAC(span: span, payload: payload),
              cac.address.web3.hexString.web3.noHexPrefix == referenceHex.lowercased() else {
            throw Error.typeMismatch
        }
        return (spanValue(span), payload)
    }

    struct SOCRead: Equatable {
        /// 64 lowercase hex chars, no `0x`.
        let identifierHex: String
        /// 130 lowercase hex chars (65-byte `r || s || v`), no `0x`.
        let signatureHex: String
        let span: UInt64
        let payload: Data
        /// EIP-55 checksummed `0x` address recovered from the signature.
        let owner: String
    }

    /// `GET /chunks/{socAddress}` body for a SOC:
    /// `identifier_32 || signature_65 || span_8LE || payload`.
    /// Recovers the signer from the EIP-191 signature over
    /// `keccak256(identifier || cacAddress)`, re-derives
    /// `keccak256(identifier || owner)` and rejects on mismatch with
    /// the requested address — the SWIP's SOC validation contract.
    static func parseSOC(addressHex: String, raw: Data) throws -> SOCRead {
        guard raw.count >= SwarmSOC.socEnvelopeSize + 1,
              raw.count <= SwarmSOC.socEnvelopeSize + SwarmSOC.maxChunkPayloadSize else {
            throw Error.typeMismatch
        }
        let identifier = Data(raw.prefix(32))
        let signature = Data(raw.dropFirst(32).prefix(65))
        let inner = Data(raw.dropFirst(32 + 65))
        let span = Data(inner.prefix(8))
        let payload = Data(inner.dropFirst(8))

        guard let cac = try? SwarmSOC.makeCAC(span: span, payload: payload) else {
            throw Error.typeMismatch
        }
        // Same signing scheme as `FeedSigner.sign`: EIP-191 personal_sign
        // over the 32-byte `keccak256(identifier || cacAddress)` digest.
        let digest = SwarmSOC.signingMessage(
            identifier: identifier, cacAddress: cac.address
        ).web3.keccak256
        let signedHash = (Data("\u{19}Ethereum Signed Message:\n32".utf8) + digest)
            .web3.keccak256
        guard let recovered = try? KeyUtil.recoverPublicKey(
            message: signedHash, signature: signature
        ), let ownerBytes = Data(hex: Hex.stripped(recovered)),
           ownerBytes.count == 20 else {
            throw Error.typeMismatch
        }
        let derived = SwarmSOC.socAddress(
            identifier: identifier, ownerAddress: ownerBytes
        )
        guard derived.web3.hexString.web3.noHexPrefix == addressHex.lowercased() else {
            throw Error.typeMismatch
        }
        return SOCRead(
            identifierHex: identifier.web3.hexString.web3.noHexPrefix,
            signatureHex: signature.web3.hexString.web3.noHexPrefix,
            span: spanValue(span),
            payload: payload,
            owner: Hex.checksummed(recovered)
        )
    }

    // MARK: - Span

    /// Highest span a JS `number` can carry losslessly
    /// (`Number.MAX_SAFE_INTEGER`, 2⁵³ − 1). Larger values cross the
    /// bridge as decimal strings and surface as `bigint` per the SWIP.
    static let maxSafeJSInteger: UInt64 = 9_007_199_254_740_991

    /// Little-endian 8-byte span decode (bee's span convention — LE,
    /// unlike the BE feed index; see `SwarmSOC`).
    static func spanValue(_ bytes: Data) -> UInt64 {
        precondition(bytes.count == 8, "span must be 8 bytes")
        return bytes.enumerated().reduce(UInt64(0)) { acc, pair in
            acc | (UInt64(pair.element) << (8 * UInt64(pair.offset)))
        }
    }

    static func spanBytes(_ value: UInt64) -> Data {
        var le = value.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }

    /// JSON-safe span for read replies: `Int` within the JS
    /// safe-integer range, decimal `String` above it (the JS preload
    /// converts strings back to `BigInt`).
    static func spanJSON(_ value: UInt64) -> Any {
        value <= maxSafeJSInteger ? Int(value) : String(value)
    }
}
