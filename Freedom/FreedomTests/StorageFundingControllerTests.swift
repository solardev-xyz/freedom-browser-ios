import XCTest
@testable import Freedom

/// The node-side funding state machine: quote, wait for xDAI, buy once.
@MainActor
final class StorageFundingControllerTests: XCTestCase {
    private var keep: [AnyObject] = []
    private var sufficient = false
    private var quoteCalls = 0
    private var buys: [(depth: UInt8, amount: String, immutable: Bool)] = []
    private var topups: [String] = []
    private var buyError: Error?
    private var activated: [StorageFundingController.Purchase] = []
    private var topupQuoteDays: [UInt64] = []

    private func quote(depth: UInt8 = 20, days: UInt64 = 30, sufficient: Bool) -> StorageQuote {
        StorageQuote(
            depth: depth, days: days, amountPerChunk: "4142000000", totalCostBzz: "0.4344",
            settlementDepositPlur: sufficient ? "0" : "10000000000000000", settlementDepositBzz: sufficient ? "0" : "1.0",
            capacityBytes: 1_000_000_000, accountBzzDisplay: "0.0000", accountXdai: "0.1", accountXdaiDisplay: "0.1000",
            neededBzzDisplay: "1.4344", xdaiRequiredDisplay: "0.5301", xdaiToSendDisplay: sufficient ? "0" : "0.4301",
            sufficientFunds: sufficient
        )
    }

    private func controller() -> StorageFundingController {
        let ffi = StorageFFI(
            quote: { [unowned self] depth, days in
                quoteCalls += 1
                return quote(depth: depth, days: days, sufficient: sufficient)
            },
            buy: { [unowned self] depth, amount, immutable in
                buys.append((depth, amount, immutable))
                try await Task.sleep(for: .milliseconds(20))
                if let buyError { throw buyError }
            },
            topupQuote: { [unowned self] days in
                topupQuoteDays.append(days)
                return quote(days: days, sufficient: sufficient)
            },
            topup: { [unowned self] amount in topups.append(amount) },
            status: { StorageStatus(enabled: true, batchID: "abcd") },
            settlementDeposit: { [unowned self] in deposit(needsTopUp: true) },
            settlementTopup: { [unowned self] in deposit(needsTopUp: false) }
        )
        let c = StorageFundingController(ffi: ffi)
        c.onActivated = { [unowned self] purchase in activated.append(purchase) }
        keep.append(c)
        return c
    }

    private func deposit(needsTopUp: Bool) -> SettlementDeposit {
        SettlementDeposit(
            enabled: true, chequebook: "0xcheq", depositBzz: needsTopUp ? "0.0" : "1.0", targetBzz: "1.0",
            shortfallBzz: needsTopUp ? "1.0" : "0", needsTopUp: needsTopUp, xdaiToSendDisplay: "0.42", sufficientFunds: true
        )
    }

    private func settle(_ c: StorageFundingController, until step: StorageFundingController.Step) async {
        await settle { c.step == step }
    }

    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    struct Boom: LocalizedError { var errorDescription: String? { "not enough xDAI: send 0.1 more" } }

    func testLoadQuotesPricesEveryPlan() async {
        let c = controller()
        await c.loadQuotes()
        XCTAssertEqual(c.quotes.count, StoragePlan.all.count)
        XCTAssertEqual(quoteCalls, StoragePlan.all.count)
        XCTAssertNil(c.error)
        XCTAssertEqual(StoragePlan.all.map(\.days), [7, 30, 30])
    }

    func testFundedNodeBuysOnceAndImmutably() async {
        sufficient = true
        let c = controller()
        let plan = StoragePlan.all[StoragePlan.defaultIndex]
        await c.start(.buy(plan))
        await settle(c, until: .done)
        XCTAssertEqual(c.step, .done)
        XCTAssertEqual(buys.count, 1)
        XCTAssertEqual(buys.first?.depth, plan.depth)
        XCTAssertEqual(buys.first?.amount, "4142000000", "the buy charges what the quote priced")
        XCTAssertEqual(buys.first?.immutable, true)
        XCTAssertEqual(activated, [.buy(plan)])
    }

    func testWaitsForPaymentThenActivatesExactlyOnce() async {
        let c = controller()
        let plan = StoragePlan.all[0]
        await c.start(.buy(plan))
        XCTAssertEqual(c.step, .payment)
        XCTAssertTrue(buys.isEmpty)
        XCTAssertEqual(c.quote?.xdaiToSendDisplay, "0.4301")

        // The transfer lands; two refreshes race in (the poll and the
        // user's tap) — still one buy.
        sufficient = true
        await c.refreshQuote()
        await c.refreshQuote()
        await settle(c, until: .done)
        XCTAssertEqual(buys.count, 1)
        XCTAssertEqual(c.step, .done)
    }

    func testFailedActivationReturnsToPaymentAndRetriesManually() async {
        sufficient = true
        buyError = Boom()
        let c = controller()
        await c.start(.buy(StoragePlan.all[0]))
        await settle { c.error != nil }
        XCTAssertEqual(c.step, .payment)
        XCTAssertEqual(c.error, "not enough xDAI: send 0.1 more")
        XCTAssertEqual(buys.count, 1)
        // No silent re-buy: a further refresh doesn't fire the buy again.
        await c.refreshQuote()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(buys.count, 1)

        buyError = nil
        await c.activate()
        XCTAssertEqual(c.step, .done)
        XCTAssertEqual(buys.count, 2)
        XCTAssertNil(c.error)
    }

    func testExtendUsesTheTopupCalls() async {
        sufficient = true
        let c = controller()
        await c.start(.extend(days: 30))
        await settle(c, until: .done)
        XCTAssertEqual(topupQuoteDays, [30])
        XCTAssertEqual(topups, ["4142000000"])
        XCTAssertTrue(buys.isEmpty)
        XCTAssertEqual(activated, [.extend(days: 30)])
    }

    func testBackClearsThePurchase() async {
        let c = controller()
        await c.start(.buy(StoragePlan.all[0]))
        c.back()
        XCTAssertEqual(c.step, .plan)
        XCTAssertNil(c.purchase)
        XCTAssertNil(c.quote)
    }

    func testDepositRefreshAndTopUp() async {
        let c = controller()
        await c.refreshDeposit()
        XCTAssertEqual(c.deposit?.needsTopUp, true)
        await c.topUpDeposit()
        XCTAssertEqual(c.deposit?.needsTopUp, false)
        XCTAssertNil(c.depositError)
        let connected = await c.connectedPlanBatchID()
        XCTAssertEqual(connected, "abcd")
    }
}
