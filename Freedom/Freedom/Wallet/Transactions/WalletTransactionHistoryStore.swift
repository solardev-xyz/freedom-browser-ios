import BigInt
import Foundation
import Observation
import OSLog
import SwiftData

private let log = Logger(subsystem: "com.browser.Freedom", category: "WalletTransactionHistory")

/// Persistent ledger of every transaction the wallet broadcast — the
/// iOS half of desktop's payment history (`payment-history.js` +
/// `tx-recorder.js`), minus x402 receipts. `TransactionService.send`
/// appends a pending row the moment the broadcast returns a hash and
/// hands it to `track`, which follows the receipt in the background; a
/// row still pending at the next launch is re-polled once by
/// `repollPending`. Writes are best-effort: a store failure never fails
/// the send.
@MainActor
@Observable
final class WalletTransactionHistoryStore {
    /// A receipt lookup: nil while the transaction is still in the mempool.
    typealias ReceiptLookup = @MainActor (_ hash: String, _ chainID: Int) async throws -> WalletRPC.TransactionReceipt?

    /// How long `track` follows a broadcast before leaving the row
    /// pending for the next launch's repoll (desktop `waitForTransaction`).
    static let trackTimeout: Duration = .seconds(600)

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var trackers: [UUID: Task<Void, Never>] = [:]
    private(set) var entries: [WalletTransactionRecord] = []

    init(context: ModelContext) {
        self.context = context
        refresh()
    }

    var pendingCount: Int { entries.filter { $0.status == .pending }.count }

    func entry(id: UUID) -> WalletTransactionRecord? {
        entries.first { $0.id == id }
    }

    @discardableResult
    func record(
        txHash: String, chainID: Int, from: String, context ctx: WalletTransactionContext
    ) -> WalletTransactionRecord {
        let row = WalletTransactionRecord(
            kind: ctx.kind, chainID: chainID, txHash: txHash, fromAddress: from,
            toAddress: ctx.toAddress, assetAddress: ctx.assetAddress,
            assetSymbol: ctx.assetSymbol, assetDecimals: ctx.assetDecimals,
            amount: ctx.amount, origin: ctx.origin
        )
        context.insert(row)
        save()
        refresh()
        return row
    }

    func markConfirmed(_ row: WalletTransactionRecord, receipt: WalletRPC.TransactionReceipt) {
        row.status = .confirmed
        row.confirmedAt = .now
        row.gasUsed = receipt.gasUsed
        row.gasPrice = receipt.effectiveGasPrice
        save()
        refresh()
    }

    func markFailed(_ row: WalletTransactionRecord, receipt: WalletRPC.TransactionReceipt?, reason: String? = nil) {
        row.status = .failed
        row.gasUsed = receipt?.gasUsed
        row.gasPrice = receipt?.effectiveGasPrice
        row.failureReason = reason
        save()
        refresh()
    }

    /// Apply a receipt (or its absence) to a pending row. Returns true
    /// when the row reached a final status.
    @discardableResult
    func apply(_ receipt: WalletRPC.TransactionReceipt?, to row: WalletTransactionRecord) -> Bool {
        guard row.status == .pending, let receipt else { return false }
        if receipt.succeeded {
            markConfirmed(row, receipt: receipt)
        } else {
            markFailed(row, receipt: receipt, reason: "Reverted on chain")
        }
        return true
    }

    /// Follow the receipt in the background at the chain's block cadence.
    /// A timeout leaves the row pending — it may still land — for the
    /// next launch's `repollPending`.
    func track(_ row: WalletTransactionRecord, pollInterval: Duration, lookup: @escaping ReceiptLookup) {
        let id = row.id
        trackers[id]?.cancel()
        trackers[id] = Task { [weak self] in
            defer { self?.trackers[id] = nil }
            let deadline = ContinuousClock.now + Self.trackTimeout
            while ContinuousClock.now < deadline, !Task.isCancelled {
                guard let self, let live = self.entry(id: id), live.status == .pending else { return }
                if let receipt = try? await lookup(live.txHash, live.chainID), self.apply(receipt, to: live) {
                    log.info("tx \(live.txHash, privacy: .public) \(live.status.rawValue, privacy: .public)")
                    return
                }
                try? await Task.sleep(for: pollInterval)
            }
            log.info("tx tracking timed out; left pending for the next launch")
        }
    }

    /// Desktop `repollPending`: one receipt lookup per row still pending
    /// from an earlier run. Errors leave the row as it is.
    @discardableResult
    func repollPending(lookup: ReceiptLookup) async -> (resolved: Int, stillPending: Int) {
        var resolved = 0
        var stillPending = 0
        for row in entries where row.status == .pending {
            do {
                if apply(try await lookup(row.txHash, row.chainID), to: row) { resolved += 1 } else { stillPending += 1 }
            } catch {
                stillPending += 1
                log.info("repoll failed for \(row.txHash, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if resolved > 0 { log.info("repoll resolved \(resolved) pending transaction(s)") }
        return (resolved, stillPending)
    }

    func delete(id: UUID) {
        guard let row = entry(id: id) else { return }
        trackers[id]?.cancel()
        context.delete(row)
        save()
        refresh()
    }

    func clearAll() {
        for task in trackers.values { task.cancel() }
        trackers.removeAll()
        for row in entries { context.delete(row) }
        save()
        refresh()
    }

    private func refresh() {
        let descriptor = FetchDescriptor<WalletTransactionRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        entries = (try? context.fetch(descriptor)) ?? []
    }

    private func save() { context.saveLogging("WalletTransactionHistory", to: log) }
}
