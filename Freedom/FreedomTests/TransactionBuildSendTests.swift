import BigInt
import XCTest
import web3
@testable import Freedom

/// `TransactionService.buildSend` translates a logical "send N of token T
/// to recipient" into the on-chain `(to, value, data)` shape. Native is
/// pass-through; ERC-20 routes through the contract with `transfer()`
/// calldata.
final class TransactionBuildSendTests: XCTestCase {
    private let recipient: EthereumAddress = "0xd8da6bf26964af9d7eed9e03e53415d37aa96045"

    private let xDAI = TokenRegistry.native(for: .gnosis)
    private let usdc = TokenRegistry.tokens(for: .mainnet).first { $0.symbol == "USDC" }!

    func testNativeSendPassesThrough() throws {
        let params = try TransactionService.buildSend(
            token: xDAI, recipient: recipient, amount: BigUInt(10).power(18)
        )
        XCTAssertEqual(params.to, recipient)
        XCTAssertEqual(params.value, BigUInt(10).power(18))
        XCTAssertTrue(params.data.isEmpty)
    }

    /// ERC-20 send routes to the token contract with `transfer()` calldata
    /// and `value=0` — the recipient lives inside the calldata.
    func testTokenSendBuildsTransferCalldata() throws {
        let params = try TransactionService.buildSend(
            token: usdc, recipient: recipient, amount: BigUInt(100_000_000)
        )
        XCTAssertEqual(params.to, usdc.address)
        XCTAssertEqual(params.value, 0)
        XCTAssertTrue(params.data.web3.hexString.hasPrefix("0xa9059cbb"))
    }
}
