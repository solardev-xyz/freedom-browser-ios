import BigInt
import Foundation

/// Helpers for `0x`-prefixed hex (the wire format for every JSON-RPC
/// numeric field). Consolidates the `hasPrefix("0x") + dropFirst(2) +
/// radix: 16` dance and the address-shape check that would otherwise
/// scatter across every dapp-param decoder and form input.
enum Hex {
    enum Error: Swift.Error {
        case invalidHex(field: String, value: String)
    }

    static func bigUInt(_ s: String) -> BigUInt? {
        BigUInt(stripped(s), radix: 16)
    }

    static func int(_ s: String) -> Int? {
        Int(stripped(s), radix: 16)
    }

    /// `0x` + 40 hex chars — the canonical Ethereum address shape. No
    /// EIP-55 checksum check; just byte/length validity.
    static func isAddressShape(_ s: String) -> Bool {
        s.count == 42
            && (s.hasPrefix("0x") || s.hasPrefix("0X"))
            && s.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    /// Reads a `0x`-prefixed BigUInt from a JSON-RPC param dict's slot.
    /// `nil` for missing (caller decides default), throws for malformed.
    static func optionalBigUInt(_ value: Any?, field: String) throws -> BigUInt? {
        guard let raw = value as? String else { return nil }
        guard let parsed = bigUInt(raw) else {
            throw Error.invalidHex(field: field, value: raw)
        }
        return parsed
    }

    static func optionalInt(_ value: Any?, field: String) throws -> Int? {
        guard let raw = value as? String else { return nil }
        guard let parsed = int(raw) else {
            throw Error.invalidHex(field: field, value: raw)
        }
        return parsed
    }

    /// Strip a `0x` or `0X` prefix; returns the input unchanged if absent.
    /// Centralises the prefix-strip dance so consumers (RPC params, address
    /// comparisons, hex-decoding entry points) all behave the same.
    static func stripped(_ s: String) -> String {
        s.hasPrefix("0x") || s.hasPrefix("0X") ? String(s.dropFirst(2)) : s
    }

    /// Canonical user-facing form: `0x` + the unprefixed hex. Idempotent
    /// on already-prefixed input. Empty input passes through (callers
    /// often guard on emptiness for "not yet known" semantics).
    static func prefixed(_ s: String) -> String {
        s.isEmpty ? s : "0x" + stripped(s)
    }
}

extension String {
    /// `0x809FA673…F68e` — keeps the `0x` prefix plus enough chars on each
    /// side for human cross-check. Returns the input unchanged if it's
    /// shorter than `prefix + suffix`.
    func shortenedHex(prefix: Int = 6, suffix: Int = 4) -> String {
        guard count > prefix + suffix else { return self }
        return "\(self.prefix(prefix))…\(self.suffix(suffix))"
    }
}
