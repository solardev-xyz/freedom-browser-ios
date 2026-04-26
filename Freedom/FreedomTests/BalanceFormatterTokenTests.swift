import BigInt
import XCTest
import web3
@testable import Freedom

/// Token-aware formatting paths. Built-in registry decimals (6, 16, 18)
/// each have edge cases that the chain-only `format(wei:on:)` path
/// doesn't exercise.
final class BalanceFormatterTokenTests: XCTestCase {
    private let usdc = Token(
        chainID: 1,
        address: EthereumAddress("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"),
        symbol: "USDC", name: "USD Coin", decimals: 6,
        logoAsset: nil
    )

    private let bzz = Token(
        chainID: 1,
        address: EthereumAddress("0x19062190B1925b5b6689D7073fDfC8c2976EF8Cb"),
        symbol: "BZZ", name: "Swarm Token", decimals: 16,
        logoAsset: nil
    )

    func testUSDCWholeAmount() {
        let value = BigUInt(100_000_000)  // 100.000000
        XCTAssertEqual(BalanceFormatter.format(wei: value, token: usdc), "100 USDC")
    }

    func testUSDCFractional() {
        let value = BigUInt(123_456)  // 0.123456
        XCTAssertEqual(BalanceFormatter.format(wei: value, token: usdc), "0.123456 USDC")
    }

    /// 1 USDC raw unit (10^-6) is exactly at the 6-digit display cap —
    /// "0.000001 USDC", not the sub-precision sentinel.
    func testUSDCSmallestRepresentable() {
        let value = BigUInt(1)
        XCTAssertEqual(BalanceFormatter.format(wei: value, token: usdc), "0.000001 USDC")
    }

    /// BZZ at 16 decimals does have sub-precision space: 1 raw unit
    /// (10^-16) is far below the 6-digit display cap, so we surface
    /// "<0.00001 BZZ" rather than rounding to zero.
    func testBZZSubPrecisionAmount() {
        let value = BigUInt(1)
        XCTAssertEqual(BalanceFormatter.format(wei: value, token: bzz), "<0.000001 BZZ")
    }

    /// BZZ uses 16 decimals, not 18 — the gotcha called out in the
    /// desktop research. 1 BZZ = 10^16 raw units.
    func testBZZWholeAmount() {
        let value = BigUInt(10).power(16)
        XCTAssertEqual(BalanceFormatter.format(wei: value, token: bzz), "1 BZZ")
    }

    func testBZZFractional() {
        // 0.5 BZZ = 5 × 10^15 raw units
        let value = BigUInt(5) * BigUInt(10).power(15)
        XCTAssertEqual(BalanceFormatter.format(wei: value, token: bzz), "0.5 BZZ")
    }

    /// Round-trip via `parseAmount` — user types "10.5", we tokenize at
    /// the asset's decimals, formatter renders the same string back.
    func testParseAndFormatRoundTrip() {
        let parsed = BalanceFormatter.parseAmount("10.5", decimals: 6)
        XCTAssertEqual(parsed, BigUInt(10_500_000))
        XCTAssertEqual(BalanceFormatter.format(wei: parsed!, token: usdc), "10.5 USDC")
    }

    /// A user typing more fractional digits than the asset has decimals
    /// is rejected — silently truncating would lose precision the user
    /// thought they were sending.
    func testParseRejectsOverPrecision() {
        XCTAssertNil(BalanceFormatter.parseAmount("0.1234567", decimals: 6))
    }

    /// `formatAmount` is the symbol-less variant used by `AssetRow` —
    /// the row already shows the symbol as a bold leading label, so the
    /// trailing balance is just the number.
    func testFormatAmountOmitsSymbol() {
        XCTAssertEqual(
            BalanceFormatter.formatAmount(wei: BigUInt(123_456), decimals: 6),
            "0.123456"
        )
        XCTAssertEqual(
            BalanceFormatter.formatAmount(wei: BigUInt(10).power(16), decimals: 16),
            "1"
        )
        XCTAssertEqual(
            BalanceFormatter.formatAmount(wei: BigUInt(1), decimals: 16),
            "<0.000001"
        )
    }
}
