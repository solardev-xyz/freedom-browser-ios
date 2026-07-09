import BigInt
import Foundation

/// Gas-price suggestion for legacy (pre-EIP-1559) transactions.
///
/// A raw `eth_gasPrice` proved unreliable in the field: one stale or
/// lowballing provider in the fan-out pool prices the tx below the
/// current base fee, it sits in the mempool, and every nonce-queued send
/// behind it stalls too (freedom-browser-ios#1). So the quote is
/// cross-checked against the latest block's `baseFeePerGas` and floored
/// at `baseFee × 1.25 + 1 gwei` — clears the next block's worst-case
/// base-fee bump (+12.5%) with margin, regardless of which provider
/// answered.
///
/// EIP-1559 type-2 transactions (`eth_feeHistory` percentiles) remain
/// the proper fix — deferred to M5.7, blocked on a type-2 RLP encoder
/// (Argent web3.swift's `EthereumTransaction` is legacy-only).
struct GasOracle {
    enum Error: Swift.Error, LocalizedError {
        /// Provider answered with something that isn't hex. Never fall
        /// back to 0 wei — a zero-priced tx sits in the mempool
        /// near-forever and nonce-blocks every send after it.
        case unparseableQuote(String)
        /// Quote and base-fee floor both came out zero — no price we
        /// could broadcast with any hope of inclusion.
        case zeroQuote

        var errorDescription: String? {
            switch self {
            case .unparseableQuote, .zeroQuote:
                return "The network returned an unusable gas price. Try again."
            }
        }
    }

    let rpc: WalletRPC

    /// ×1.25 headroom over the latest base fee.
    private static let headroomNumerator = BigUInt(125)
    private static let headroomDenominator = BigUInt(100)
    /// Miner tip on top of the floored base fee — the 1-gwei default
    /// priority fee most wallets bid.
    private static let tipWei = BigUInt(1_000_000_000)

    func suggestedGasPrice(on chain: Chain) async throws -> BigUInt {
        async let quoteHex = rpc.gasPrice(on: chain)
        async let header = rpc.latestBlockHeader(on: chain)

        let hex = try await quoteHex
        guard let quote = Hex.bigUInt(hex) else {
            throw Error.unparseableQuote(hex)
        }
        // nil on pre-London chains — no base fee exists, the quote stands.
        let baseFee = try await header.baseFeePerGas.flatMap(Hex.bigUInt)
        let floor = baseFee.map {
            $0 * Self.headroomNumerator / Self.headroomDenominator + Self.tipWei
        }
        let price = max(quote, floor ?? 0)
        guard price > 0 else { throw Error.zeroQuote }
        return price
    }
}
