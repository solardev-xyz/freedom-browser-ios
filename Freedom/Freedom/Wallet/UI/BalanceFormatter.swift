import BigInt
import Foundation

/// Converts a hex-encoded balance into a human-readable string like
/// `"1.2345 xDAI"` or `"100.5 USDC"`. Token-aware via the `decimals`
/// parameter — USDC is 6, BZZ is 16, native chains are 18.
enum BalanceFormatter {
    static func format(weiHex: String, on chain: Chain, maxFractionDigits: Int = 6) -> String {
        guard let wei = parse(weiHex: weiHex) else { return "—" }
        return format(wei: wei, decimals: nativeDecimals, symbol: chain.nativeSymbol, maxFractionDigits: maxFractionDigits)
    }

    static func format(wei: BigUInt, on chain: Chain, maxFractionDigits: Int = 6) -> String {
        format(wei: wei, decimals: nativeDecimals, symbol: chain.nativeSymbol, maxFractionDigits: maxFractionDigits)
    }

    static func format(wei: BigUInt, token: Token, maxFractionDigits: Int = 6) -> String {
        format(wei: wei, decimals: token.decimals, symbol: token.symbol, maxFractionDigits: maxFractionDigits)
    }

    /// Native-decimals shorthand. Used by send-flow call sites that don't
    /// (yet) thread a `Token` through.
    static func format(wei: BigUInt, symbol: String, maxFractionDigits: Int = 6) -> String {
        format(wei: wei, decimals: nativeDecimals, symbol: symbol, maxFractionDigits: maxFractionDigits)
    }

    static func parse(weiHex: String) -> BigUInt? {
        Hex.bigUInt(weiHex)
    }

    /// Inverse of `format` — user-typed "0.1" → 10¹⁷ wei (for an 18-decimal
    /// asset). Returns `nil` for malformed input or values with more
    /// fractional digits than the asset has decimals.
    static func parseAmount(_ input: String, decimals: Int = nativeDecimals) -> BigUInt? {
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

    static func format(wei: BigUInt, decimals: Int, symbol: String, maxFractionDigits: Int = 6) -> String {
        "\(formatAmount(wei: wei, decimals: decimals, maxFractionDigits: maxFractionDigits)) \(symbol)"
    }

    /// Number-only variant for places that already display the symbol
    /// elsewhere in the layout (e.g. asset rows where the symbol is in
    /// the row's leading label).
    static func formatAmount(wei: BigUInt, decimals: Int, maxFractionDigits: Int = 6) -> String {
        let divisor = BigUInt(10).power(decimals)
        let whole = wei / divisor
        let remainder = wei % divisor

        if remainder == 0 {
            return "\(whole)"
        }

        let raw = String(remainder)
        let padded = String(repeating: "0", count: decimals - raw.count) + raw
        let truncated = String(padded.prefix(maxFractionDigits))
        let trimmed = String(truncated.reversed().drop(while: { $0 == "0" }).reversed())

        if trimmed.isEmpty {
            // Non-zero but smaller than our precision — surface that
            // explicitly rather than rounding away to zero.
            return "<0.\(String(repeating: "0", count: maxFractionDigits - 1))1"
        }
        return "\(whole).\(trimmed)"
    }

    static let nativeDecimals = 18
}
