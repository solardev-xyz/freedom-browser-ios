import BigInt
import XCTest
import web3
@testable import Freedom

/// `FundNodeBuilder` is hand-rolled ABI encoding for the SwarmNodeFunder
/// contract. Tests validate the byte-level shape of the calldata: correct
/// selector, correct arg order, correct padding, all-zeros stamp tuple
/// for the v1 "skip stamp" path.
final class FundNodeBuilderTests: XCTestCase {
    private let beeWallet: EthereumAddress = "0xd8da6bf26964af9d7eed9e03e53415d37aa96045"
    private let xdaiSwap = BigUInt(10).power(18)        // 1 xDAI
    private let xdaiBee = BigUInt(50_000_000_000_000_000)  // 0.05 xDAI
    private let minBzz = BigUInt(947) * BigUInt(10).power(13)  // 0.0947 BZZ in PLUR

    // MARK: - Method ID

    /// Pinning the actual 4-byte hex of the method ID — anyone editing
    /// `signature` (drops a member, renames a type, fat-fingers a
    /// parenthesis) breaks this test, NOT silently breaks every produced
    /// tx in production. Recomputing from the same constant the encoder
    /// uses would be tautological.
    func testMethodIDPinnedToContractSignature() {
        // First 4 bytes of:
        //   keccak256("fundNodeAndBuyStamp(address,uint256,uint256,(uint256,uint8,uint8,bytes32,bool))")
        // Cross-checked against the deployed contract on Gnosis (Blockscout, 2026-04-24).
        let expectedHex = "0x834aeb80"
        XCTAssertEqual(
            "0x" + FundNodeBuilder.methodID().web3.hexString.web3.noHexPrefix,
            expectedHex
        )
    }

    // MARK: - Calldata shape

    func testCalldataLengthMatches3HeadArgsPlus5TupleSlots() throws {
        let (_, _, data) = try FundNodeBuilder.build(
            beeWallet: beeWallet,
            xdaiForSwap: xdaiSwap,
            xdaiForBee: xdaiBee,
            minBzzOut: minBzz
        )
        // 4 selector + 3 head args (32 each) + 5 tuple slots (32 each) = 260
        XCTAssertEqual(data.count, 260)
    }

    func testCalldataPrefixIsMethodID() throws {
        let (_, _, data) = try FundNodeBuilder.build(
            beeWallet: beeWallet,
            xdaiForSwap: xdaiSwap,
            xdaiForBee: xdaiBee,
            minBzzOut: minBzz
        )
        XCTAssertEqual(data.prefix(4), FundNodeBuilder.methodID())
    }

    /// First 32-byte slot after the selector is the bee-wallet address —
    /// 12 zero bytes of left-pad, then the 20-byte address.
    func testFirstHeadSlotIsBeeWalletAddress() throws {
        let (_, _, data) = try FundNodeBuilder.build(
            beeWallet: beeWallet,
            xdaiForSwap: xdaiSwap,
            xdaiForBee: xdaiBee,
            minBzzOut: minBzz
        )
        let slot = data.subdata(in: 4..<36)
        XCTAssertEqual(slot.prefix(12), Data(repeating: 0, count: 12))
        let addrBytes = slot.suffix(20)
        XCTAssertEqual(
            "0x" + addrBytes.web3.hexString.web3.noHexPrefix,
            beeWallet.asString().lowercased()
        )
    }

    /// Slots 2 and 3 are `xdaiToLeaveForBee` and `minBzzOut`. Roundtrip:
    /// big-endian-decode each slot back to BigUInt and assert equality.
    func testHeadSlotsCarryNumericArgs() throws {
        let (_, _, data) = try FundNodeBuilder.build(
            beeWallet: beeWallet,
            xdaiForSwap: xdaiSwap,
            xdaiForBee: xdaiBee,
            minBzzOut: minBzz
        )
        let slot2 = data.subdata(in: 36..<68)
        let slot3 = data.subdata(in: 68..<100)
        XCTAssertEqual(BigUInt(slot2), xdaiBee)
        XCTAssertEqual(BigUInt(slot3), minBzz)
    }

    /// All five tuple slots are zero in v1 — `depth = 0` is what tells
    /// the contract to skip the stamp purchase. If a future caller passes
    /// real stamp args this test will rightly fail and force the surface
    /// to grow at the same time.
    func testStampTupleIsAllZeros() throws {
        let (_, _, data) = try FundNodeBuilder.build(
            beeWallet: beeWallet,
            xdaiForSwap: xdaiSwap,
            xdaiForBee: xdaiBee,
            minBzzOut: minBzz
        )
        let tuple = data.suffix(160)
        XCTAssertEqual(tuple, Data(repeating: 0, count: 160))
    }

    // MARK: - Tx tuple

    func testTxValueIsSwapPlusBee() throws {
        let (_, value, _) = try FundNodeBuilder.build(
            beeWallet: beeWallet,
            xdaiForSwap: xdaiSwap,
            xdaiForBee: xdaiBee,
            minBzzOut: minBzz
        )
        XCTAssertEqual(value, xdaiSwap + xdaiBee)
    }

    func testTxToIsFunderAddress() throws {
        let (to, _, _) = try FundNodeBuilder.build(
            beeWallet: beeWallet,
            xdaiForSwap: xdaiSwap,
            xdaiForBee: xdaiBee,
            minBzzOut: minBzz
        )
        XCTAssertEqual(to, SwarmFunderConstants.funderAddress)
    }
}
