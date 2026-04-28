import BigInt
import Foundation

/// Depth/amount/cost computations for postage batches. Mirrors bee-js
/// `utils/stamps.js` exactly — same breakpoint table, same `+1` safety
/// margin, same formula for cost — so the values our app sends to bee
/// match what desktop Freedom would send for the same preset.
///
/// Bee uses 1000-base storage units (consistent with the Swarm papers
/// on theoretical/effective capacity), and Gnosis runs ~5s blocks.
enum StampMath {
    /// Effective-size table from bee-js's `effectiveSizeBreakpoints`.
    /// Each row is "at depth N, an unencrypted batch effectively stores
    /// G GB" (1 GB = 1e9 bytes here, not 2^30). Below 17 a batch can't
    /// hold anything useful; above 34 we approximate at 90% theoretical.
    static let effectiveSizeGBBreakpoints: [(depth: Int, gb: Double)] = [
        (17, 0.00004089),
        (18, 0.00609),
        (19, 0.10249),
        (20, 0.62891),
        (21, 2.38),
        (22, 7.07),
        (23, 18.24),
        (24, 43.04),
        (25, 96.5),
        (26, 208.52),
        (27, 435.98),
        (28, 908.81),
        (29, 1870),
        (30, 3810),
        (31, 7730),
        (32, 15610),
        (33, 31430),
        (34, 63150),
    ]

    /// Smallest depth that holds at least `bytes` of effective storage.
    /// Bee-js's `getDepthForSize` (no encryption / erasure variant). For
    /// inputs beyond the table, returns 35 (bee's max).
    static func depthForSize(bytes: Int) -> Int {
        for (depth, gb) in effectiveSizeGBBreakpoints {
            if bytes <= Int(gb * 1_000_000_000) {
                return depth
            }
        }
        return 35
    }

    /// Effective bytes at a given depth (reverse lookup). Below 17
    /// returns 0; above 34 falls back to `theoreticalBytes × 0.9`.
    static func effectiveBytes(forDepth depth: Int) -> Int {
        if depth < 17 { return 0 }
        if let row = effectiveSizeGBBreakpoints.first(where: { $0.depth == depth }) {
            return Int(row.gb * 1_000_000_000)
        }
        return Int(Double(theoreticalBytes(depth: depth)) * 0.9)
    }

    /// Raw chunk capacity, `4096 × 2^depth`. Used as the >34 fallback.
    static func theoreticalBytes(depth: Int) -> Int {
        return 4096 * (1 << depth)
    }

    /// `amount` for `POST /stamps/{amount}/{depth}`. Mirrors bee-js's
    /// `getAmountForDuration`. The trailing `+1` is bee's safety margin
    /// so the batch lasts at least the requested duration even when
    /// `seconds / blockSeconds` rounds down.
    static func amountForDuration(seconds: Int, pricePerBlock: Int, blockSeconds: Int = 5) -> BigUInt {
        let blocks = BigUInt(seconds) / BigUInt(blockSeconds)
        return blocks * BigUInt(pricePerBlock) + BigUInt(1)
    }

    /// Total batch cost in PLUR. `2^depth × amount`. Matches bee-js's
    /// `getStampCost`.
    static func costPlur(depth: Int, amount: BigUInt) -> BigUInt {
        return (BigUInt(1) << depth) * amount
    }
}
