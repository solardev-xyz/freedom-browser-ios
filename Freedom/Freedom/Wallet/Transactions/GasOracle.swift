import BigInt
import Foundation

/// Minimal gas-price suggestion for legacy (pre-EIP-1559) transactions.
/// `eth_gasPrice` returns what the node considers a reasonable bid for
/// next-block inclusion — perfectly fine on Gnosis (low, stable baseFee)
/// and acceptable on Mainnet for user-initiated sends where the user is
/// paying once, not running arbitrage.
///
/// EIP-1559 with `eth_feeHistory` + percentile priority fees is the next
/// upgrade — deferred until M5.7 polish.
struct GasOracle {
    let rpc: WalletRPC

    func suggestedGasPrice(on chain: Chain) async throws -> BigUInt {
        let hex = try await rpc.gasPrice(on: chain)
        return Hex.bigUInt(hex) ?? BigUInt(0)
    }
}
