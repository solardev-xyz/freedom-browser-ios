import BigInt
import Foundation
import web3

/// ABI helpers for the ERC-20 methods we need.
enum ERC20Coder {
    static func encodeBalanceOf(holder: EthereumAddress) throws -> Data {
        let encoder = ABIFunctionEncoder("balanceOf")
        try encoder.encode(holder)
        return try encoder.encoded()
    }

    /// Selector `0xa9059cbb` || ABI(address recipient, uint256 amount).
    /// `to` is always the recipient — the tx itself is sent to the token
    /// contract, with `value=0`.
    static func encodeTransfer(to: EthereumAddress, amount: BigUInt) throws -> Data {
        let encoder = ABIFunctionEncoder("transfer")
        try encoder.encode(to)
        try encoder.encode(amount)
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
