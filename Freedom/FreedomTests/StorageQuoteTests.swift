import XCTest
@testable import Freedom

/// ant's storage JSON as the app reads it, plus the payment helpers.
final class StorageQuoteTests: XCTestCase {
    func testDecodesAntStorageQuote() throws {
        let json = """
        {"depth":20,"days":30,"amount_per_chunk":"4142000000","total_cost_plur":"4343128064000000",
         "total_cost_bzz":"0.4343","settlement_deposit_plur":"10000000000000000","settlement_deposit_bzz":"1.0000",
         "capacity_bytes":1073741824,"account_bzz":"0","account_bzz_display":"0.0000","account_xdai":"0.05",
         "account_xdai_display":"0.0500","needed_bzz":"14343128064000000","needed_bzz_display":"1.4343",
         "xdai_required":"0.5301","xdai_required_display":"0.5301","xdai_to_send":"0.4801",
         "xdai_to_send_display":"0.4801","sufficient_funds":false}
        """
        let quote = try StorageQuote.decode(json)
        XCTAssertEqual(quote.depth, 20)
        XCTAssertEqual(quote.days, 30)
        XCTAssertEqual(quote.amountPerChunk, "4142000000")
        XCTAssertEqual(quote.xdaiToSendDisplay, "0.4801")
        XCTAssertFalse(quote.sufficientFunds)
        XCTAssertTrue(quote.includesSettlementDeposit)
        XCTAssertFalse(quote.coveredByNodeBzz)
        XCTAssertEqual(StorageFundingView.sendLine(for: quote), "send 0.49 xDAI")
        XCTAssertTrue(StorageFundingView.coverageLine(for: quote).hasPrefix("Covers the 0.4343 xBZZ"))
    }

    /// A node that already holds the xBZZ (left over from the old funder
    /// flow) is only asked for ant's gas reserve — the plan card must not
    /// present that as the plan's price.
    func testNodeHoldingBzzIsAskedForFeesOnly() throws {
        let json = """
        {"depth":21,"days":30,"amount_per_chunk":"4142000000","total_cost_plur":"8686256128000000",
         "total_cost_bzz":"0.8686","settlement_deposit_plur":"0","settlement_deposit_bzz":"0.0000",
         "capacity_bytes":2147483648,"account_bzz":"50000000000000000","account_bzz_display":"5.0000","account_xdai":"0",
         "account_xdai_display":"0.0000","needed_bzz":"0","needed_bzz_display":"0.0000",
         "xdai_required":"15000000000000000","xdai_required_display":"0.0150","xdai_to_send":"0.015",
         "xdai_to_send_display":"0.0150","sufficient_funds":false}
        """
        let quote = try StorageQuote.decode(json)
        XCTAssertTrue(quote.coveredByNodeBzz)
        XCTAssertEqual(StorageFundingView.sendLine(for: quote), "send 0.02 xDAI for fees")
        XCTAssertTrue(StorageFundingView.coverageLine(for: quote).hasPrefix("Your node already holds the 0.8686 xBZZ"))
    }

    func testDecodesSettlementDepositAndStatus() throws {
        let deposit = try SettlementDeposit.decode("""
        {"enabled":true,"chequebook":"0xabc","deposit_plur":"0","deposit_bzz":"0.0000","target_plur":"10000000000000000",
         "target_bzz":"1.0000","shortfall_plur":"10000000000000000","shortfall_bzz":"1.0000","needs_top_up":true,
         "xdai_required":"0.4","xdai_required_display":"0.4000","xdai_to_send":"0.35","xdai_to_send_display":"0.3500",
         "sufficient_funds":false}
        """)
        XCTAssertTrue(deposit.needsTopUp)
        XCTAssertEqual(deposit.shortfallBzz, "1.0000")
        let status = try StorageStatus.decode(#"{"enabled":true,"batch_id":"deadbeef","batch_depth":20}"#)
        XCTAssertEqual(status.batchID, "deadbeef")
        let off = try StorageStatus.decode(#"{"enabled":false}"#)
        XCTAssertNil(off.batchID)
    }

    func testRoundsUpToTheNextCent() {
        XCTAssertEqual(StoragePayment.roundedUpXdai("0.4301"), "0.44")
        XCTAssertEqual(StoragePayment.roundedUpXdai("0.50"), "0.50")
        XCTAssertEqual(StoragePayment.roundedUpXdai("2"), "2.00")
        XCTAssertEqual(StoragePayment.roundedUpXdai("0"), "0.00")
        XCTAssertEqual(StoragePayment.roundedUpXdai("n/a"), "n/a")
    }

    func testBuildsAnEIP681PaymentRequestOnGnosis() {
        let uri = StoragePayment.paymentURI(nodeAddress: "0x1111111111111111111111111111111111111111", xdai: "0.44")
        XCTAssertEqual(uri, "ethereum:0x1111111111111111111111111111111111111111@100?value=440000000000000000")
        XCTAssertEqual(
            StoragePayment.paymentURI(nodeAddress: "0x1111111111111111111111111111111111111111", xdai: "x"),
            "ethereum:0x1111111111111111111111111111111111111111@100"
        )
    }

    func testPlansFollowTheStampPresets() {
        XCTAssertEqual(StoragePlan.all.map(\.label), StampService.presets.map(\.label))
        XCTAssertEqual(StoragePlan.all[2].depth, UInt8(StampMath.depthForSize(bytes: 5_000_000_000)))
    }
}
