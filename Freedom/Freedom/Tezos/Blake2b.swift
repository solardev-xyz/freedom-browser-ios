import Foundation

/// Minimal unkeyed BLAKE2b (RFC 7693) for Tezos ScriptExpr hashing —
/// desktop's `src/shared/blake2b.js`. Domain resolution hashes only
/// short big-map keys, so a small local implementation beats pulling a
/// cryptography dependency in for one primitive.
enum Blake2b {
    private static let iv: [UInt64] = [
        0x6a09_e667_f3bc_c908, 0xbb67_ae85_84ca_a73b, 0x3c6e_f372_fe94_f82b, 0xa54f_f53a_5f1d_36f1,
        0x510e_527f_ade6_82d1, 0x9b05_688c_2b3e_6c1f, 0x1f83_d9ab_fb41_bd6b, 0x5be0_cd19_137e_2179,
    ]
    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    ]

    /// Digest of `input` with `outputLength` bytes (1…64).
    static func hash(_ input: Data, outputLength: Int = 32) -> Data {
        precondition((1...64).contains(outputLength), "BLAKE2b output length must be 1…64 bytes")
        var state = iv
        state[0] ^= 0x0101_0000 ^ UInt64(outputLength)
        let bytes = [UInt8](input)
        var offset = 0
        while offset + 128 < bytes.count {
            compress(&state, Array(bytes[offset..<(offset + 128)]), counter: UInt64(offset + 128), last: false)
            offset += 128
        }
        var final = Array(bytes[offset...])
        final += [UInt8](repeating: 0, count: 128 - final.count)
        compress(&state, final, counter: UInt64(bytes.count), last: true)
        var out = Data(capacity: outputLength)
        for index in 0..<outputLength {
            out.append(UInt8(truncatingIfNeeded: state[index / 8] >> (UInt64(index % 8) * 8)))
        }
        return out
    }

    private static func compress(_ state: inout [UInt64], _ block: [UInt8], counter: UInt64, last: Bool) {
        var m = [UInt64](repeating: 0, count: 16)
        for index in 0..<16 {
            var word: UInt64 = 0
            for byte in 0..<8 { word |= UInt64(block[index * 8 + byte]) << (UInt64(byte) * 8) }
            m[index] = word
        }
        var v = state + iv
        v[12] ^= counter
        // The high counter word stays zero: inputs here are far below 2^64 bytes.
        if last { v[14] = ~v[14] }
        for s in sigma {
            mix(&v, 0, 4, 8, 12, m[s[0]], m[s[1]])
            mix(&v, 1, 5, 9, 13, m[s[2]], m[s[3]])
            mix(&v, 2, 6, 10, 14, m[s[4]], m[s[5]])
            mix(&v, 3, 7, 11, 15, m[s[6]], m[s[7]])
            mix(&v, 0, 5, 10, 15, m[s[8]], m[s[9]])
            mix(&v, 1, 6, 11, 12, m[s[10]], m[s[11]])
            mix(&v, 2, 7, 8, 13, m[s[12]], m[s[13]])
            mix(&v, 3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for index in 0..<8 { state[index] ^= v[index] ^ v[index + 8] }
    }

    @inline(__always)
    private static func mix(_ v: inout [UInt64], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
        v[a] = v[a] &+ v[b] &+ x
        v[d] = rotr(v[d] ^ v[a], 32)
        v[c] = v[c] &+ v[d]
        v[b] = rotr(v[b] ^ v[c], 24)
        v[a] = v[a] &+ v[b] &+ y
        v[d] = rotr(v[d] ^ v[a], 16)
        v[c] = v[c] &+ v[d]
        v[b] = rotr(v[b] ^ v[c], 63)
    }

    @inline(__always)
    private static func rotr(_ value: UInt64, _ shift: UInt64) -> UInt64 {
        (value >> shift) | (value << (64 - shift))
    }
}
