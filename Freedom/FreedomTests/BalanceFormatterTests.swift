import BigInt
import XCTest
@testable import Freedom

final class BalanceFormatterTests: XCTestCase {
    private let gnosis = Chain.gnosis
    private let mainnet = Chain.mainnet

    func testExactWhole() {
        // 1 xDAI = 10^18 wei
        XCTAssertEqual(
            BalanceFormatter.format(weiHex: "0xde0b6b3a7640000", on: gnosis),
            "1 xDAI"
        )
    }

    func testFractional() {
        // 0.5 xDAI = 5 × 10^17 wei
        XCTAssertEqual(
            BalanceFormatter.format(weiHex: "0x6f05b59d3b20000", on: gnosis),
            "0.5 xDAI"
        )
    }

    func testTruncatesToSixDefault() {
        // 1.23456789 ETH — digits beyond 6 should be dropped, not rounded.
        let wei = BigUInt("1234567890000000000", radix: 10)!
        XCTAssertEqual(
            BalanceFormatter.format(wei: wei, symbol: "ETH"),
            "1.234567 ETH"
        )
    }

    func testTrimsTrailingFractionalZeros() {
        // 1.5 ETH — padded would be 500000000000000000; trimmed to "5".
        let wei = BigUInt("1500000000000000000", radix: 10)!
        XCTAssertEqual(
            BalanceFormatter.format(wei: wei, symbol: "ETH"),
            "1.5 ETH"
        )
    }

    func testZero() {
        XCTAssertEqual(BalanceFormatter.format(weiHex: "0x0", on: mainnet), "0 ETH")
    }

    func testSubPrecisionShowsLowerBound() {
        // 1 wei — well below 10⁻⁶ ETH. We show "<0.000001 ETH" rather than
        // rounding to 0, which would be dishonest.
        XCTAssertEqual(
            BalanceFormatter.format(weiHex: "0x1", on: mainnet),
            "<0.000001 ETH"
        )
    }

    func testLargeValueWithinBigUIntRange() {
        // 100 ETH = 100 × 10^18 wei = 0x56BC75E2D63100000 (17 hex digits)
        XCTAssertEqual(
            BalanceFormatter.format(weiHex: "0x56bc75e2d63100000", on: mainnet),
            "100 ETH"
        )
    }

    func testHexWithoutPrefix() {
        // Parser should accept both "0x…" and bare hex.
        XCTAssertEqual(
            BalanceFormatter.format(weiHex: "de0b6b3a7640000", on: gnosis),
            "1 xDAI"
        )
    }

    func testInvalidHex() {
        XCTAssertEqual(
            BalanceFormatter.format(weiHex: "not-hex", on: mainnet),
            "—"
        )
    }
}
