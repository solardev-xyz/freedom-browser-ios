import BigInt
import XCTest
import web3
@testable import Freedom

final class ERC20CoderTests: XCTestCase {
    /// `balanceOf(0xd8da...) == 0x70a08231 || abi.encode(address)`.
    /// `0x70a08231` = `bytes4(keccak256("balanceOf(address)"))`. The
    /// padded address is the canonical ABI shape — left-padded to a
    /// 32-byte word.
    func testEncodeBalanceOf() throws {
        let holder: EthereumAddress = "0xd8da6bf26964af9d7eed9e03e53415d37aa96045"
        let encoded = try ERC20Coder.encodeBalanceOf(holder: holder)
        let hex = encoded.web3.hexString
        XCTAssertTrue(hex.hasPrefix("0x70a08231"),
                      "selector mismatch — got \(hex.prefix(10))")
        // 4-byte selector + 32-byte word = 36 bytes = 72 hex chars + 0x.
        XCTAssertEqual(hex.count, 2 + 4 * 2 + 32 * 2)
    }

    func testDecodeBalanceTypicalUSDC() {
        // 100.000000 USDC (6 decimals) = 100_000_000 raw units, ABI-padded
        // to a 32-byte word.
        let hex = String(format: "0x%064x", 100_000_000)
        XCTAssertEqual(ERC20Coder.decodeBalance(hex: hex), BigUInt(100_000_000))
    }

    func testDecodeZeroBalance() {
        let hex = "0x" + String(repeating: "0", count: 64)
        XCTAssertEqual(ERC20Coder.decodeBalance(hex: hex), BigUInt(0))
    }

    func testDecodeMalformedHexReturnsNil() {
        XCTAssertNil(ERC20Coder.decodeBalance(hex: "0xnothex"))
    }
}
