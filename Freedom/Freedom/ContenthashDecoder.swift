import Foundation
import web3

/// Decoder for EIP-1577 ENS contenthash bytes.
///
/// Spec layout: `<protoCode varint><value>` where protoCode is a
/// multicodec varint identifying the namespace, and value is
/// protocol-specific (CID for IPFS/IPNS, swarm reference for Swarm).
///
/// Multicodec values relevant here:
///   ipfs-ns  = 0xe3 → varint `e3 01`
///   ipns-ns  = 0xe5 → varint `e5 01`
///   swarm-ns = 0xe4 → varint `e4 01`
/// (All have the high bit set in the first byte, so the varint
/// terminator is the second byte `0x01`. IOW: namespace is 2 bytes.)
enum ContenthashDecoder {
    enum DecodeError: Error {
        case abiUnwrapFailed
    }

    /// The Universal Resolver wraps `contenthash(bytes32)`'s `bytes`
    /// return inside its own `bytes result` — so we need to ABI-decode
    /// one extra layer of `bytes` to get to the raw EIP-1577 contenthash.
    static func unwrapABIBytes(_ abiEncoded: Data) throws -> Data {
        let hex = abiEncoded.web3.hexString
        do {
            let decoded = try ABIDecoder.decodeData(hex, types: [Data.self])
            return try decoded[0].decoded()
        } catch {
            throw DecodeError.abiUnwrapFailed
        }
    }

    /// Parse raw EIP-1577 contenthash bytes into a navigable URI.
    /// Returns nil for unsupported protocols / malformed inputs.
    static func decode(_ bytes: Data) -> (uri: URL, codec: ENSContentCodec)? {
        // Swarm: namespace varint `e4 01` + CIDv1 (`01`) + swarm-manifest
        // codec varint (`fa 01`) + keccak256-32 multihash (`1b 20 + 32B`).
        // Total prefix 7B + 32B digest = 39B.
        if bytes.count == 7 + 32,
           bytes.starts(with: [0xe4, 0x01, 0x01, 0xfa, 0x01, 0x1b, 0x20]) {
            let hash = bytes.suffix(32).map { String(format: "%02hhx", $0) }.joined()
            return (URL(string: "bzz://\(hash)")!, .bzz)
        }

        // IPFS / IPNS share the same value structure (a CID). Strip the
        // 2-byte namespace varint, then decode the value as CIDv0 or CIDv1.
        if bytes.starts(with: [0xe3, 0x01]),
           let cid = encodeCID(bytes.dropFirst(2)) {
            return (URL(string: "ipfs://\(cid)")!, .ipfs)
        }
        if bytes.starts(with: [0xe5, 0x01]),
           let cid = encodeCID(bytes.dropFirst(2)) {
            return (URL(string: "ipns://\(cid)")!, .ipns)
        }

        return nil
    }

    /// Encode an IPFS/IPNS value (the bytes following the namespace
    /// varint) as a string suitable for the URI host component.
    ///
    /// CID forms accepted:
    ///   - **CIDv0**: bare multihash starting with `0x12 0x20` (sha256/32).
    ///     Renders as base58 `Qm…`. Only valid for dag-pb content.
    ///   - **CIDv1**: `<0x01> <codec varint> <multihash>`. The canonical
    ///     dag-pb + sha256/32 case renders as `Qm…` (CIDv0 form, bytes-
    ///     equivalent) for history-key compat with the older decoder.
    ///     All other codec/hash combinations render as multibase-`b`
    ///     CIDv1 base32 (`bafy…` / `bafk…` / `bafz…` / etc.).
    ///
    /// Validates structure — version byte, codec varint, multihash header
    /// length matches digest. Rejects malformed inputs so a corrupted
    /// contenthash can't sneak past as a valid URI.
    private static func encodeCID(_ value: Data.SubSequence) -> String? {
        guard !value.isEmpty else { return nil }

        // CIDv0: bare multihash, dag-pb implicit. Only sha256 multihash
        // (function code 0x12) is canonical for v0 per IPFS convention.
        if value.first == 0x12, value.count >= 2 {
            let declaredLen = Int(value[value.startIndex + 1])
            guard value.count == 2 + declaredLen else { return nil }
            return Base58.encode(Data(value))
        }

        // CIDv1: <version=0x01> <codec varint> <multihash>.
        // Min: 1 + 1 + 2 + 1 = 5 bytes (single-byte codec + smallest digest).
        guard value.first == 0x01, value.count >= 5 else { return nil }

        let afterVersion = value.dropFirst()
        guard let codecConsumed = varintBytes(afterVersion) else { return nil }
        let afterCodec = afterVersion.dropFirst(codecConsumed)

        // Multihash header: hashFn(1) | digestLen(1) | digest(digestLen).
        guard afterCodec.count >= 2 else { return nil }
        let digestLength = Int(afterCodec[afterCodec.startIndex + 1])
        guard afterCodec.count == 2 + digestLength else { return nil }

        // Canonical legacy form (CIDv1 + dag-pb + sha256/32) → emit
        // CIDv0 base58 (Qm…). Identical bytes; CIDv0 just omits the
        // version+codec prefix because dag-pb is implicit.
        let isDagPb = (codecConsumed == 1 && afterVersion.first == 0x70)
        let isSha256_32 = afterCodec.starts(with: [0x12, 0x20])
        if isDagPb && isSha256_32 {
            return Base58.encode(Data(afterCodec))
        }

        // Everything else: multibase 'b' (lowercase base32, RFC 4648,
        // no padding) over the full CIDv1 byte sequence.
        return "b" + base32Lower(Data(value))
    }

    /// Number of bytes consumed by the varint at the start of `bytes`,
    /// or nil if no terminator (MSB-clear byte) appears within 8 bytes.
    /// All multicodec values we care about are < 16384, so the varint
    /// fits in 1-2 bytes; the 8-byte cap is defensive.
    private static func varintBytes(_ bytes: Data.SubSequence) -> Int? {
        var consumed = 0
        for byte in bytes.prefix(8) {
            consumed += 1
            if byte & 0x80 == 0 { return consumed }
        }
        return nil
    }

    /// Lowercase base32 (RFC 4648) without padding. Multibase 'b' alphabet.
    private static func base32Lower(_ data: Data) -> String {
        let alphabet: [Character] = Array("abcdefghijklmnopqrstuvwxyz234567")
        var result = ""
        var buffer: UInt64 = 0
        var bits: Int = 0
        for byte in data {
            buffer = (buffer << 8) | UInt64(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                let idx = Int((buffer >> bits) & 0x1F)
                result.append(alphabet[idx])
            }
        }
        if bits > 0 {
            let idx = Int((buffer << (5 - bits)) & 0x1F)
            result.append(alphabet[idx])
        }
        return result
    }
}
