import Foundation
import web3

enum ContenthashDecoder {
    enum DecodeError: Error {
        case abiUnwrapFailed
    }

    /// The resolver's `contenthash(bytes32)` returns `bytes`, which the UR
    /// passes through as its `bytes result` return. ABI-decoding the UR
    /// response at the leg gave us that outer `bytes` payload; unwrapping
    /// one more `bytes` layer yields the raw EIP-1577 contenthash.
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
    /// Returns nil for unsupported codecs. IPFS/IPNS decoding preserves
    /// CIDv0 base58 form so history/bookmark keys keyed on the older URI
    /// shape keep matching.
    static func decode(_ bytes: Data) -> (uri: URL, codec: ENSContentCodec)? {
        // Swarm: 0xe40101fa011b20 + 32-byte keccak hash
        if bytes.count == 7 + 32,
           bytes.starts(with: [0xe4, 0x01, 0x01, 0xfa, 0x01, 0x1b, 0x20]) {
            let hash = bytes.suffix(32).map { String(format: "%02hhx", $0) }.joined()
            return (URL(string: "bzz://\(hash)")!, .bzz)
        }

        // IPFS: 0xe3010170 + multihash
        if bytes.starts(with: [0xe3, 0x01, 0x70]),
           let cid = base58Multihash(bytes.dropFirst(3)) {
            return (URL(string: "ipfs://\(cid)")!, .ipfs)
        }

        // IPNS: 0xe5010172 + multihash
        if bytes.starts(with: [0xe5, 0x01, 0x72]),
           let cid = base58Multihash(bytes.dropFirst(3)) {
            return (URL(string: "ipns://\(cid)")!, .ipns)
        }

        return nil
    }

    /// Multihash layout: code(1) | length(1) | digest(length). Validate
    /// the declared length matches available bytes, then base58-encode
    /// the whole multihash (not just the digest) — that's what produces
    /// the "Qm…" CIDv0 output consumers expect.
    private static func base58Multihash(_ bytes: Data.SubSequence) -> String? {
        guard bytes.count >= 2 else { return nil }
        let declaredLength = Int(bytes[bytes.startIndex + 1])
        guard bytes.count == 2 + declaredLength else { return nil }
        return Base58.encode(Data(bytes))
    }
}
