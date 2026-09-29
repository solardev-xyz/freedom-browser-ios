import BigInt
import SwiftData
import XCTest
import web3
@testable import Freedom

/// The wallet's transaction ledger — desktop payment-history parity for
/// the kinds iOS signs: pending on broadcast, confirmed / failed from
/// the receipt, re-polled once at launch.
@MainActor
final class WalletTransactionHistoryTests: XCTestCase {
    private var container: ModelContainer!
    private var store: WalletTransactionHistoryStore!
    private var keep: [AnyObject] = []

    override func setUp() async throws {
        container = try inMemoryContainer(for: WalletTransactionRecord.self)
        store = WalletTransactionHistoryStore(context: container.mainContext)
        keep.append(store)
    }

    private let sender = "0x1111111111111111111111111111111111111111"
    private let recipient = EthereumAddress("0x2222222222222222222222222222222222222222")

    private func native(_ amount: BigUInt = 5, origin: String? = nil, kind: WalletTransactionKind = .walletSend) -> WalletTransactionContext {
        WalletTransactionContext(kind: kind, toAddress: recipient.asString(), assetAddress: nil, assetSymbol: "xDAI", assetDecimals: 18, amount: amount, origin: origin)
    }

    private func receipt(status: String, gasUsed: String = "0x5208", price: String = "0x3b9aca00") -> WalletRPC.TransactionReceipt {
        WalletRPC.TransactionReceipt(status: status, blockNumber: "0x10", gasUsed: gasUsed, effectiveGasPrice: price)
    }

    func testRecordIsPendingAndNewestFirst() {
        let first = store.record(txHash: "0xaa", chainID: 100, from: sender, context: native())
        let second = store.record(txHash: "0xbb", chainID: 1, from: sender, context: native(7, origin: "https://app.example", kind: .dappSend))
        XCTAssertEqual(store.entries.map(\.txHash), ["0xbb", "0xaa"])
        XCTAssertEqual(first.status, .pending)
        XCTAssertEqual(store.pendingCount, 2)
        XCTAssertEqual(second.origin, "https://app.example")
        XCTAssertEqual(second.amountValue, 7)
        XCTAssertEqual(second.token.symbol, "xDAI")
    }

    func testReceiptDrivesTheFinalStatus() {
        let ok = store.record(txHash: "0xaa", chainID: 100, from: sender, context: native())
        XCTAssertTrue(store.apply(receipt(status: "0x1"), to: ok))
        XCTAssertEqual(ok.status, .confirmed)
        XCTAssertNotNil(ok.confirmedAt)
        XCTAssertEqual(ok.gasUsed, "0x5208")
        XCTAssertEqual(ok.gasPrice, "0x3b9aca00")

        let reverted = store.record(txHash: "0xbb", chainID: 100, from: sender, context: native())
        XCTAssertTrue(store.apply(receipt(status: "0x0"), to: reverted))
        XCTAssertEqual(reverted.status, .failed)
        XCTAssertEqual(reverted.failureReason, "Reverted on chain")

        let mempool = store.record(txHash: "0xcc", chainID: 100, from: sender, context: native())
        XCTAssertFalse(store.apply(nil, to: mempool))
        XCTAssertEqual(mempool.status, .pending)
        // A final row never flips back.
        XCTAssertFalse(store.apply(receipt(status: "0x0"), to: ok))
        XCTAssertEqual(ok.status, .confirmed)
        XCTAssertEqual(store.pendingCount, 1)
    }

    func testRepollResolvesWhatItCanAndKeepsTheRest() async {
        store.record(txHash: "0xaa", chainID: 100, from: sender, context: native())
        store.record(txHash: "0xbb", chainID: 100, from: sender, context: native())
        store.record(txHash: "0xcc", chainID: 1, from: sender, context: native())
        struct Down: Error {}
        let outcome = await store.repollPending { hash, _ in
            switch hash {
            case "0xaa": return self.receipt(status: "0x1")
            case "0xbb": return nil
            default: throw Down()
            }
        }
        XCTAssertEqual(outcome.resolved, 1)
        XCTAssertEqual(outcome.stillPending, 2)
        XCTAssertEqual(store.entry(id: store.entries.first { $0.txHash == "0xaa" }!.id)?.status, .confirmed)
    }

    func testTrackFollowsTheReceipt() async throws {
        let row = store.record(txHash: "0xaa", chainID: 100, from: sender, context: native())
        var calls = 0
        store.track(row, pollInterval: .milliseconds(10)) { _, _ in
            calls += 1
            return calls < 3 ? nil : self.receipt(status: "0x1")
        }
        for _ in 0..<50 where row.status == .pending { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(row.status, .confirmed)
        XCTAssertEqual(calls, 3)
    }

    func testDappSendIsDescribedAsTheTransferTheUserSees() throws {
        let chain = Chain.gnosis
        let token = TokenRegistry.tokens(for: chain).first { !$0.isNative }!
        let calldata = try ERC20Coder.encodeTransfer(to: recipient, amount: 1_500)
        let transfer = WalletTransactionContext.describing(
            kind: .dappSend, to: token.address!, valueWei: 0, data: calldata,
            chain: chain, tokens: TokenRegistry.tokens(for: chain), origin: "https://app.example"
        )
        XCTAssertEqual(transfer.toAddress.lowercased(), recipient.asString().lowercased())
        XCTAssertEqual(transfer.assetSymbol, token.symbol)
        XCTAssertEqual(transfer.assetDecimals, token.decimals)
        XCTAssertEqual(transfer.amount, 1_500)
        XCTAssertEqual(transfer.assetAddress?.lowercased(), token.address?.asString().lowercased())

        let plain = WalletTransactionContext.describing(
            kind: .dappSend, to: recipient, valueWei: 9, data: Data([0x01, 0x02]),
            chain: chain, tokens: [], origin: nil
        )
        XCTAssertEqual(plain.assetSymbol, "xDAI")
        XCTAssertNil(plain.assetAddress)
        XCTAssertEqual(plain.amount, 9)
        XCTAssertNil(ERC20Coder.decodeTransfer(data: Data([0xa9, 0x05, 0x9c, 0xbb])))
    }

    func testReceiptDecodesFromRPCShape() throws {
        let json = #"{"status":"0x1","blockNumber":"0x2a","gasUsed":"0x5208","effectiveGasPrice":"0x1","logs":[]}"#
        let receipt = try RPCSession.decoder.decode(WalletRPC.TransactionReceipt.self, from: Data(json.utf8))
        XCTAssertTrue(receipt.succeeded)
        XCTAssertEqual(receipt.blockNumber, "0x2a")
        let legacy = try RPCSession.decoder.decode(WalletRPC.TransactionReceipt.self, from: Data(#"{"blockNumber":"0x1"}"#.utf8))
        XCTAssertFalse(legacy.succeeded)
    }

    func testFormatting() {
        let row = store.record(txHash: "0xaa", chainID: 100, from: sender, context: native(BigUInt(10).power(18), origin: "https://app.example", kind: .dappSend))
        XCTAssertEqual(WalletActivityFormatting.title(row), "Sent 1 xDAI")
        XCTAssertTrue(WalletActivityFormatting.subtitle(row, chain: .gnosis).hasPrefix("https://app.example · Gnosis Chain"))
        XCTAssertEqual(WalletActivityFormatting.abbreviated(recipient.asString()), "0x2222…2222")
        store.markConfirmed(row, receipt: receipt(status: "0x1", gasUsed: "0x5208", price: "0x3b9aca00"))
        XCTAssertEqual(WalletActivityFormatting.fee(row, chain: .gnosis), BalanceFormatter.format(wei: BigUInt(21_000) * BigUInt(1_000_000_000), on: .gnosis))
        let call = store.record(txHash: "0xbb", chainID: 100, from: sender, context: native(0, kind: .dappSend))
        XCTAssertEqual(WalletActivityFormatting.title(call), "Contract call")
    }
}
