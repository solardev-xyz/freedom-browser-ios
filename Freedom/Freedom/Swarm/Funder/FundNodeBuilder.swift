import BigInt
import Foundation
import web3

/// Hand-rolled ABI encoder for `SwarmNodeFunder.fundNodeAndBuyStamp(...)`.
///
/// Why hand-rolled: web3.swift's `ABIFunctionEncoder` has no public surface
/// for inline static tuples. The Solidity signature
///
///     fundNodeAndBuyStamp(address,uint256,uint256,(uint256,uint8,uint8,bytes32,bool))
///
/// needs the tuple as part of the *signature* used to derive the method ID,
/// and the tuple itself as inline 32-byte words in the calldata. Both are
/// straightforward; we just stitch the bytes ourselves rather than fight
/// the encoder API for a one-shot.
///
/// All v1 callers pass a stamp tuple of all zeros (`depth = 0` skips the
/// stamp purchase per the contract; the renderer in WP3 wires real stamp
/// args here).
enum FundNodeBuilder {
    enum Error: Swift.Error {
        case invalidAddress(String)
        case overflow(field: String)
    }

    /// `value` is the total xDAI sent (`xdaiForSwap + xdaiForBee`); the
    /// contract internally splits it.
    static func build(
        beeWallet: EthereumAddress,
        xdaiForSwap: BigUInt,
        xdaiForBee: BigUInt,
        minBzzOut: BigUInt
    ) throws -> (to: EthereumAddress, value: BigUInt, data: Data) {
        let calldata = try encodeCalldata(
            beeWallet: beeWallet,
            xdaiForBee: xdaiForBee,
            minBzzOut: minBzzOut
        )
        return (
            SwarmFunderConstants.funderAddress,
            xdaiForSwap + xdaiForBee,
            calldata
        )
    }

    // MARK: - ABI

    /// Solidity signature literal — drives the method-ID hash. Must match
    /// the deployed contract bit-for-bit; a typo here makes every tx
    /// revert with a meaningless "unknown function" error.
    static let signature =
        "fundNodeAndBuyStamp(address,uint256,uint256,(uint256,uint8,uint8,bytes32,bool))"

    static func methodID() -> Data {
        Data(signature.utf8).web3.keccak256.prefix(4)
    }

    /// Selector || head(beeWallet, xdai, minBzz) || stamp tuple inline.
    /// All five members of the stamp tuple are static types (uint256,
    /// uint8, uint8, bytes32, bool), so the tuple is encoded inline at
    /// the head — no offset pointer.
    private static func encodeCalldata(
        beeWallet: EthereumAddress,
        xdaiForBee: BigUInt,
        minBzzOut: BigUInt
    ) throws -> Data {
        var out = methodID()
        out.append(try encodeAddress(beeWallet))
        out.append(encodeUInt256(xdaiForBee))
        out.append(encodeUInt256(minBzzOut))
        out.append(encodeStampTuple())
        return out
    }

    /// `depth = 0` means "skip stamp purchase". Stamps land in WP3.
    private static func encodeStampTuple() -> Data {
        var tuple = Data()
        tuple.append(encodeUInt256(0))                  // initialBalancePerChunk
        tuple.append(encodeUInt256(0))                  // depth (uint8 in 32-byte slot)
        tuple.append(encodeUInt256(0))                  // bucketDepth
        tuple.append(Data(repeating: 0, count: 32))     // nonce (bytes32)
        tuple.append(encodeUInt256(0))                  // immutableFlag (false)
        return tuple
    }

    private static func encodeAddress(_ addr: EthereumAddress) throws -> Data {
        let stripped = Hex.stripped(addr.asString())
        guard stripped.count == 40, let bytes = Data(hex: stripped) else {
            throw Error.invalidAddress(addr.asString())
        }
        return Data(repeating: 0, count: 12) + bytes  // left-pad 20 → 32
    }

    private static func encodeUInt256(_ value: BigUInt) -> Data {
        let raw = value.serialize()
        if raw.count >= 32 { return raw.suffix(32) }
        return Data(repeating: 0, count: 32 - raw.count) + raw
    }
}
