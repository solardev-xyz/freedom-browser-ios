import BigInt
import XCTest
@testable import Freedom

/// Golden-vector tests for `StampMath`. The values must match what
/// bee-js `getDepthForSize`, `getAmountForDuration`, and `getStampCost`
/// would produce for the same inputs — so users on iOS pay the same
/// for the same preset as desktop Freedom users.
final class StampMathTests: XCTestCase {

    // MARK: - Depth

    /// 1 GB sits between the 0.62891 GB (depth 20) and 2.38 GB (depth 21)
    /// breakpoints, so bee-js returns depth 21 — the smallest that fits.
    func testDepthForOneGigabyte() {
        XCTAssertEqual(StampMath.depthForSize(bytes: 1_000_000_000), 21)
    }

    /// 5 GB exceeds the 2.38 GB / depth-21 row → depth 22 (capacity 7.07 GB).
    func testDepthForFiveGigabytes() {
        XCTAssertEqual(StampMath.depthForSize(bytes: 5_000_000_000), 22)
    }

    /// Hitting the 18.24 GB row exactly should still return that row's
    /// depth (the comparison is `<=`).
    func testDepthAtBreakpointReturnsThatRow() {
        XCTAssertEqual(StampMath.depthForSize(bytes: Int(18.24 * 1_000_000_000)), 23)
    }

    /// Above the highest row (63150 GB), bee-js caps at 35.
    func testDepthCapsAtMax() {
        XCTAssertEqual(
            StampMath.depthForSize(bytes: 100_000 * 1_000_000_000),
            35
        )
    }

    /// Round-tripping the breakpoint table: every entry's depth should
    /// recover its row's effective bytes. Cheap golden coverage of all
    /// 18 rows in one test.
    func testEffectiveBytesRoundTripsBreakpointTable() {
        for (depth, gb) in StampMath.effectiveSizeGBBreakpoints {
            let expected = Int(gb * 1_000_000_000)
            XCTAssertEqual(StampMath.effectiveBytes(forDepth: depth), expected)
        }
    }

    // MARK: - Amount

    /// 7 days on Gnosis (5s blocks) at price 24000 PLUR/block:
    ///   blocks = 7 × 86400 / 5 = 120960
    ///   amount = 120960 × 24000 + 1 = 2,903,040,001 PLUR/chunk
    /// Matches bee-js `getAmountForDuration(Duration.fromDays(7), 24000, 5)`.
    func testAmountForSevenDaysAtPrice24000() {
        let amount = StampMath.amountForDuration(
            seconds: 7 * 86_400,
            pricePerBlock: 24_000
        )
        XCTAssertEqual(amount, BigUInt(2_903_040_001))
    }

    /// 30 days on Gnosis at price 24000:
    ///   blocks = 30 × 86400 / 5 = 518400
    ///   amount = 518400 × 24000 + 1 = 12,441,600,001 PLUR/chunk
    func testAmountForThirtyDaysAtPrice24000() {
        let amount = StampMath.amountForDuration(
            seconds: 30 * 86_400,
            pricePerBlock: 24_000
        )
        XCTAssertEqual(amount, BigUInt(12_441_600_001))
    }

    /// Block time is `5` by default for Gnosis but bee-js passes `15` for
    /// other networks — confirm the parameter is respected.
    func testAmountRespectsBlockTime() {
        let gnosis = StampMath.amountForDuration(
            seconds: 60, pricePerBlock: 1000, blockSeconds: 5
        )
        let mainnet = StampMath.amountForDuration(
            seconds: 60, pricePerBlock: 1000, blockSeconds: 15
        )
        // Gnosis: 12 blocks × 1000 + 1 = 12001
        // Mainnet: 4 blocks × 1000 + 1 = 4001
        XCTAssertEqual(gnosis, BigUInt(12_001))
        XCTAssertEqual(mainnet, BigUInt(4_001))
    }

    // MARK: - Cost

    /// `cost = 2^depth × amount`. For the "Try it out" preset
    /// (1 GB, 7 days, depth 21, amount 2,903,040,001) at price 24000:
    ///   cost = 2^21 × 2,903,040,001 = 6,088,335,365,898,240 ≈ 0.6088 BZZ
    func testCostForTryItOutPreset() {
        let amount = StampMath.amountForDuration(
            seconds: 7 * 86_400, pricePerBlock: 24_000
        )
        let cost = StampMath.costPlur(depth: 21, amount: amount)
        XCTAssertEqual(cost, BigUInt(2_097_152) * BigUInt(2_903_040_001))
        // Sanity: ~0.6 BZZ at 1e16 PLUR/BZZ
        XCTAssertGreaterThan(cost, BigUInt(5) * BigUInt(10).power(15))
        XCTAssertLessThan(cost, BigUInt(7) * BigUInt(10).power(15))
    }
}
