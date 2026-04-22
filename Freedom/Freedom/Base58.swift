import Foundation

enum Base58 {
    // Bitcoin alphabet (excludes visually ambiguous 0/O/I/l).
    private static let alphabet: [Character] = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    /// Encode raw bytes as base58 (no checksum). Used for ENS IPFS/IPNS
    /// contenthash decoding — a multihash base58-encodes to "Qm…" (CIDv0).
    static func encode(_ data: Data) -> String {
        var leadingZeros = 0
        for byte in data {
            if byte == 0 { leadingZeros += 1 } else { break }
        }

        var digits: [UInt8] = []
        for byte in data {
            var carry = Int(byte)
            for i in 0..<digits.count {
                carry += Int(digits[i]) << 8
                digits[i] = UInt8(carry % 58)
                carry /= 58
            }
            while carry > 0 {
                digits.append(UInt8(carry % 58))
                carry /= 58
            }
        }

        var out = String(repeating: "1", count: leadingZeros)
        for digit in digits.reversed() {
            out.append(alphabet[Int(digit)])
        }
        return out
    }
}
