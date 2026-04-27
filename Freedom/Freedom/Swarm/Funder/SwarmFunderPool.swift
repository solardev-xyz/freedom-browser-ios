import BigInt
import Foundation
import web3

/// Reads the BZZ/WXDAI UniswapV3 pool's `slot0()` to derive the live spot
/// price. We only need `sqrtPriceX96` (the first uint160 in the response);
/// the other six fields are ignored.
///
/// Goes through the same `WalletRPC` we use for every other Gnosis read,
/// so the pool query benefits from the existing fan-out + provider
/// quarantine logic.
@MainActor
struct SwarmFunderPool {
    let walletRPC: WalletRPC

    enum Error: Swift.Error {
        case invalidResponse
    }

    /// `slot0()` selector is `0x3850c7bd` — keccak256("slot0()")[:4]. We
    /// hard-code the bytes rather than recomputing every call; if Uniswap
    /// V3 ever ships a new pool ABI we'd be picking that up via a new
    /// pool address anyway.
    private static let slot0Calldata = Data([0x38, 0x50, 0xc7, 0xbd])

    /// Read the pool's current sqrtPriceX96. Returns nil if the call
    /// fails or the response shape is unexpected — callers treat that
    /// as "quote unavailable, try again" rather than as a zero price.
    func fetchSqrtPriceX96() async throws -> BigUInt {
        let tx: [String: String] = [
            "to": SwarmFunderConstants.poolAddress.asString(),
            "data": Self.slot0Calldata.web3.hexString,
        ]
        let raw = try await walletRPC.callJSON(
            method: "eth_call", params: [tx, "latest"], on: .gnosis
        )
        guard let hex = raw as? String,
              let bytes = Data(hex: hex),
              bytes.count >= 32 else {
            throw Error.invalidResponse
        }
        // First 32-byte word holds the uint160 sqrtPriceX96 (left-padded).
        return BigUInt(bytes.prefix(32))
    }

    /// Returned price is "xDAI per BZZ" — what the rest of the funder
    /// pipeline consumes.
    func fetchSpotXdaiPerBzz() async throws -> Double {
        let sqrtPriceX96 = try await fetchSqrtPriceX96()
        return SwarmFunderQuote.spotXdaiPerBzz(sqrtPriceX96: sqrtPriceX96)
    }
}
