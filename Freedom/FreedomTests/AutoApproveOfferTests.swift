import BigInt
import XCTest
import web3
@testable import Freedom

final class AutoApproveOfferTests: XCTestCase {
    private let usdc: EthereumAddress = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
    private let origin = "app.uniswap.org"

    /// `transfer(address,uint256)` selector + zero value → eligible.
    func testTransferCallProducesOffer() {
        let data = Data([0xa9, 0x05, 0x9c, 0xbb]) + Data(repeating: 0, count: 64)
        let offer = AutoApproveOffer.make(origin: origin, to: usdc, valueWei: 0, data: data, chainID: 1)
        XCTAssertNotNil(offer)
        XCTAssertEqual(offer?.selector, "0xa9059cbb")
        XCTAssertEqual(offer?.selectorLabel, "token transfers")
        XCTAssertEqual(offer?.chainID, 1)
    }

    /// Plain ETH send (empty data) → ineligible. Zero-selector ETH sends
    /// are exactly the case §7 says we never auto-approve.
    func testEmptyDataReturnsNil() {
        XCTAssertNil(AutoApproveOffer.make(origin: origin, to: usdc, valueWei: 0, data: Data(), chainID: 1))
    }

    /// Selector that's all-zero bytes ≡ `0x00000000` → ineligible. Some
    /// payable contracts can be called with this shape and we treat it
    /// the same as a plain ETH send.
    func testZeroSelectorReturnsNil() {
        let data = Data(repeating: 0, count: 36)  // 4 zero selector bytes + a word
        XCTAssertNil(AutoApproveOffer.make(origin: origin, to: usdc, valueWei: 0, data: data, chainID: 1))
    }

    /// Value-bearing call, even on a known selector, never offers the
    /// toggle: the user's consent for "always approve transfer" doesn't
    /// extend to "always send ETH along with the call".
    func testNonZeroValueReturnsNil() {
        let data = Data([0xa9, 0x05, 0x9c, 0xbb]) + Data(repeating: 0, count: 64)
        let offer = AutoApproveOffer.make(origin: origin, to: usdc, valueWei: 1, data: data, chainID: 1)
        XCTAssertNil(offer)
    }

    /// Unknown selector → still eligible (custom dapp functions are the
    /// main use case), but the label is nil so the UI falls back to the
    /// "calls to this contract" copy.
    func testUnknownSelectorIsStillEligible() {
        let data = Data([0xab, 0xcd, 0xef, 0x01]) + Data(repeating: 0, count: 32)
        let offer = AutoApproveOffer.make(origin: origin, to: usdc, valueWei: 0, data: data, chainID: 1)
        XCTAssertNotNil(offer)
        XCTAssertEqual(offer?.selector, "0xabcdef01")
        XCTAssertNil(offer?.selectorLabel)
    }

    /// Less than 4 bytes of data isn't a function call at all.
    func testTruncatedDataReturnsNil() {
        let data = Data([0xa9, 0x05, 0x9c])
        XCTAssertNil(AutoApproveOffer.make(origin: origin, to: usdc, valueWei: 0, data: data, chainID: 1))
    }
}
