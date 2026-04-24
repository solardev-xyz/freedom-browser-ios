import BigInt
import Foundation

/// Tiny helpers for decoding `0x`-prefixed hex (the wire format for every
/// JSON-RPC numeric field). Consolidates the `hasPrefix("0x") + dropFirst(2)
/// + radix: 16` dance that was duplicated across the transactions module.
enum Hex {
    static func bigUInt(_ s: String) -> BigUInt? {
        BigUInt(stripped(s), radix: 16)
    }

    static func int(_ s: String) -> Int? {
        Int(stripped(s), radix: 16)
    }

    private static func stripped(_ s: String) -> String {
        s.hasPrefix("0x") ? String(s.dropFirst(2)) : s
    }
}
