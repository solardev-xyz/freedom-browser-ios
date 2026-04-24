import BigInt
import Foundation

/// Converts a hex-encoded wei balance into a human-readable string like
/// `"1.2345 xDAI"`. Uses BigUInt because native-token balances can exceed
/// UInt64 (1.8e19 ≈ 18.4 ETH) for any meaningfully-funded wallet.
enum BalanceFormatter {
    /// `maxFractionDigits` truncates rather than rounds — showing a balance
    /// *higher* than reality would be dishonest; truncation is always safe.
    static func format(weiHex: String, on chain: Chain, maxFractionDigits: Int = 6) -> String {
        guard let wei = parse(weiHex: weiHex) else { return "—" }
        return format(wei: wei, symbol: chain.nativeSymbol, maxFractionDigits: maxFractionDigits)
    }

    static func parse(weiHex: String) -> BigUInt? {
        Hex.bigUInt(weiHex)
    }

    /// Inverse of `format` — user-typed "0.1" → 10¹⁷ wei. Returns `nil` for
    /// malformed input or values with more fractional digits than the token
    /// has decimals (18). The intentional round-trip guarantees we never
    /// silently truncate what the user typed.
    static func parseAmount(_ input: String) -> BigUInt? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let whole = String(parts[0])
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard whole.allSatisfy(\.isNumber), fraction.allSatisfy(\.isNumber) else { return nil }
        guard fraction.count <= decimals else { return nil }
        let padded = fraction + String(repeating: "0", count: decimals - fraction.count)
        return BigUInt((whole.isEmpty ? "0" : whole) + padded)
    }

    static func format(wei: BigUInt, symbol: String, maxFractionDigits: Int = 6) -> String {
        let whole = wei / divisor18
        let remainder = wei % divisor18

        if remainder == 0 {
            return "\(whole) \(symbol)"
        }

        // Pad remainder to full precision, then truncate + trim trailing zeros.
        let raw = String(remainder)
        let padded = String(repeating: "0", count: Self.decimals - raw.count) + raw
        let truncated = String(padded.prefix(maxFractionDigits))
        let trimmed = String(truncated.reversed().drop(while: { $0 == "0" }).reversed())

        if trimmed.isEmpty {
            // Balance is non-zero but smaller than our precision — surface
            // that explicitly rather than rounding to zero.
            return "<0.\(String(repeating: "0", count: maxFractionDigits - 1))1 \(symbol)"
        }
        return "\(whole).\(trimmed) \(symbol)"
    }

    /// All v1 chains use 18-decimal native tokens (ETH on Mainnet, xDAI on
    /// Gnosis). If we ever add a non-18-decimal chain, split this into
    /// per-chain decimals and drop the assumption.
    private static let decimals = 18
    private static let divisor18 = BigUInt(10).power(18)
}
