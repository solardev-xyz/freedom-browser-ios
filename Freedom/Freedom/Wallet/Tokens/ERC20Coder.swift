import BigInt
import Foundation
import web3

/// ABI helpers for the ERC-20 read methods we need. `transfer` lands in
/// WP21 alongside the send flow.
enum ERC20Coder {
    static func encodeBalanceOf(holder: EthereumAddress) throws -> Data {
        let encoder = ABIFunctionEncoder("balanceOf")
        try encoder.encode(holder)
        return try encoder.encoded()
    }

    /// `eth_call` returns the uint256 balance ABI-encoded as a single
    /// 32-byte word. Returns nil on malformed input — callers treat that
    /// as "balance unavailable for this token", not as zero.
    static func decodeBalance(hex: String) -> BigUInt? {
        guard let parsed = try? ABIDecoder.decodeData(hex, types: [BigUInt.self]).first,
              let value: BigUInt = try? parsed.decoded() else {
            return nil
        }
        return value
    }
}
