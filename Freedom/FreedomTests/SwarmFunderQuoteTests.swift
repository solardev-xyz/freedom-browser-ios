import BigInt
import XCTest
@testable import Freedom

/// `SwarmFunderQuote` is pure math — no I/O — so the tests pin the
/// numerical contract that has to match desktop's `swarm-funder-service.js`
/// for any given (sqrtPriceX96, xdai, slippageBps). A drift here would
/// surface as iOS quoting a different price than desktop for the same
/// pool reading.
final class SwarmFunderQuoteTests: XCTestCase {
    // MARK: - Spot price

    /// Construct a sqrtPriceX96 corresponding to a known target spot, run
    /// it back through the decoder, assert we recover the target. Round-
    /// trip via Double has bounded precision loss (`Double` is 53-bit
    /// significand, sqrtPriceX96 is 96 bits) — `accuracy:` swallows the
    /// last few digits.
    func testSpotRoundTrip() {
        // Target: 0.1 xDAI per BZZ. Pool token order: token0=BZZ (16 dec),
        // token1=WXDAI (18 dec). raw price (token1/token0) = target * 100.
        let target = 0.1
        let rawPrice = target * 100.0  // 10
        let sqrtFloat = rawPrice.squareRoot()
        let twoPow96 = BigUInt(1) << 96
        let sqrtPriceX96 = BigUInt(sqrtFloat * Double(twoPow96))

        let recovered = SwarmFunderQuote.spotXdaiPerBzz(sqrtPriceX96: sqrtPriceX96)
        XCTAssertEqual(recovered, target, accuracy: 1e-9)
    }

    func testSpotZeroOnZeroInput() {
        XCTAssertEqual(
            SwarmFunderQuote.spotXdaiPerBzz(sqrtPriceX96: 0),
            0.0
        )
    }

    // MARK: - Quote math

    /// Sanity check at a clean spot: 1 xDAI in @ 0.1 xDAI/BZZ → ~10 BZZ
    /// before fee and slippage. Pool fee 30 bps → 9.97 BZZ expected.
    /// Slippage 500 bps → minOut = expected * 0.95 ≈ 9.47 BZZ.
    func testQuoteAtKnownSpot() {
        let oneXdai = BigUInt(10).power(18)
        let result = SwarmFunderQuote.quote(
            xdaiForSwapWei: oneXdai,
            spotXdaiPerBzz: 0.1,
            slippageBps: 500
        )
        // BZZ has 16 decimals → 1 BZZ = 10^16 PLUR.
        let expectedBzz = Double(result.expectedBzzPlur) / 1e16
        let minBzz = Double(result.minBzzOutPlur) / 1e16

        XCTAssertEqual(expectedBzz, 9.97, accuracy: 0.01)
        XCTAssertEqual(minBzz, 9.97 * 0.95, accuracy: 0.01)
    }

    /// Slippage of 0 yields minOut == expected. Slippage of 10000 (100%)
    /// yields minOut = 0. Bracketing the math.
    func testSlippageBracket() {
        let oneXdai = BigUInt(10).power(18)
        let zeroSlip = SwarmFunderQuote.quote(
            xdaiForSwapWei: oneXdai, spotXdaiPerBzz: 0.1, slippageBps: 0
        )
        XCTAssertEqual(zeroSlip.expectedBzzPlur, zeroSlip.minBzzOutPlur)

        let fullSlip = SwarmFunderQuote.quote(
            xdaiForSwapWei: oneXdai, spotXdaiPerBzz: 0.1, slippageBps: 10_000
        )
        XCTAssertEqual(fullSlip.minBzzOutPlur, 0)
    }

    /// Zero spot or zero input → zero quote, no division-by-zero crash.
    func testZeroInputs() {
        let zeroSpot = SwarmFunderQuote.quote(
            xdaiForSwapWei: BigUInt(10).power(18),
            spotXdaiPerBzz: 0.0,
            slippageBps: 500
        )
        XCTAssertEqual(zeroSpot.expectedBzzPlur, 0)
        XCTAssertEqual(zeroSpot.minBzzOutPlur, 0)

        let zeroXdai = SwarmFunderQuote.quote(
            xdaiForSwapWei: 0,
            spotXdaiPerBzz: 0.1,
            slippageBps: 500
        )
        XCTAssertEqual(zeroXdai.expectedBzzPlur, 0)
        XCTAssertEqual(zeroXdai.minBzzOutPlur, 0)
    }

    /// Doubling the swap amount roughly doubles the BZZ output (linear
    /// at the spot-price level — actual on-chain quote is non-linear due
    /// to concentrated liquidity, but our quote is the no-slippage proxy).
    func testQuoteScalesLinearlyAtFixedSpot() {
        let one = SwarmFunderQuote.quote(
            xdaiForSwapWei: BigUInt(10).power(18),
            spotXdaiPerBzz: 0.1,
            slippageBps: 500
        )
        let two = SwarmFunderQuote.quote(
            xdaiForSwapWei: BigUInt(2) * BigUInt(10).power(18),
            spotXdaiPerBzz: 0.1,
            slippageBps: 500
        )
        // Expect 2× within Double rounding noise.
        let ratio = Double(two.expectedBzzPlur) / Double(one.expectedBzzPlur)
        XCTAssertEqual(ratio, 2.0, accuracy: 1e-9)
    }
}
