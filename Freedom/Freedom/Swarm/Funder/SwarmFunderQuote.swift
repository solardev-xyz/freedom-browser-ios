import BigInt
import Foundation

/// Pure quote math for the SwarmNodeFunder one-tx flow. No I/O, no actor
/// isolation. Caller fetches the pool spot price (see `SwarmFunderPool`)
/// and feeds it in alongside the swap amount and slippage.
///
/// Mirrors `freedom-browser/src/main/swarm/swarm-funder-service.js`'s
/// `expectedBzzOut` + `minBzzOut` math 1:1 — same Double precision, same
/// rounding, so a given (xdai, spot, slippage) input lands on the same
/// minBzzOut on iOS as on desktop.
enum SwarmFunderQuote {
    struct Result: Equatable {
        /// Best estimate of BZZ tokens we'd get out, ignoring price impact
        /// of the swap itself (concentrated-liquidity slope makes real
        /// output slightly lower).
        let expectedBzzPlur: BigUInt
        /// Slippage-protected floor. The on-chain swap reverts if the
        /// pool can't deliver at least this much.
        let minBzzOutPlur: BigUInt
    }

    /// Pool token order: token0 = BZZ (16 dec), token1 = WXDAI (18 dec).
    /// Raw `(sqrtPriceX96/2^96)^2` is "raw WXDAI per raw BZZ"; the decimal
    /// scale converts to "xDAI per BZZ" in human units.
    static func spotXdaiPerBzz(sqrtPriceX96: BigUInt) -> Double {
        guard sqrtPriceX96 > 0 else { return 0 }
        let twoPow96 = BigUInt(1) << 96
        let sqrtFloat = Double(sqrtPriceX96) / Double(twoPow96)
        let rawPrice = sqrtFloat * sqrtFloat
        let decimalScale = pow(
            10.0,
            Double(SwarmFunderConstants.bzzDecimals - SwarmFunderConstants.wxdaiDecimals)
        )
        return rawPrice * decimalScale
    }

    /// Spot ≤ 0 yields a zero quote — caller should refresh the pool
    /// price before showing.
    static func quote(
        xdaiForSwapWei: BigUInt,
        spotXdaiPerBzz: Double,
        slippageBps: Int = SwarmFunderConstants.defaultSlippageBps
    ) -> Result {
        guard spotXdaiPerBzz > 0, xdaiForSwapWei > 0 else {
            return Result(expectedBzzPlur: 0, minBzzOutPlur: 0)
        }
        let xdaiFloat = Double(xdaiForSwapWei) / 1e18
        let feeMultiplier = 1.0 - Double(SwarmFunderConstants.poolFeeBps) / 10_000.0
        let bzzFloat = (xdaiFloat * feeMultiplier) / spotXdaiPerBzz
        let bzzPlurFloat = max(
            0,
            bzzFloat * pow(10.0, Double(SwarmFunderConstants.bzzDecimals))
        )
        let expected = BigUInt(bzzPlurFloat)
        let slippageNum = BigUInt(max(0, 10_000 - slippageBps))
        let minOut = expected * slippageNum / 10_000
        return Result(expectedBzzPlur: expected, minBzzOutPlur: minOut)
    }
}
