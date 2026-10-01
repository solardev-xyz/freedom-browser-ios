import Foundation
import Observation
import SwarmKit
import OSLog

private let log = Logger(subsystem: "com.browser.Freedom", category: "StorageFunding")

/// The node-side storage calls the funding flow needs, as closures so
/// the flow can be driven in tests without a node. Production wraps
/// `SwarmNode`'s `ant_storage_*` calls.
struct StorageFFI {
    var quote: @MainActor (_ depth: UInt8, _ days: UInt64) async throws -> StorageQuote
    var buy: @MainActor (_ depth: UInt8, _ amountPerChunk: String, _ immutable: Bool) async throws -> Void
    var topupQuote: @MainActor (_ days: UInt64) async throws -> StorageQuote
    var topup: @MainActor (_ amountPerChunk: String) async throws -> Void
    var status: @MainActor () async throws -> StorageStatus
    var settlementDeposit: @MainActor () async throws -> SettlementDeposit
    var settlementTopup: @MainActor () async throws -> SettlementDeposit
    /// `ant_deploy_chequebook`: deploy or adopt the chequebook and
    /// switch settlement on. Returns the address.
    var deployChequebook: @MainActor () async throws -> String

    @MainActor
    static func live(_ node: SwarmNode) -> StorageFFI {
        StorageFFI(
            quote: { depth, days in try StorageQuote.decode(try await node.storageQuote(depth: depth, days: days)) },
            buy: { depth, amount, immutable in _ = try await node.storageBuyXdai(depth: depth, amountPerChunk: amount, immutable: immutable) },
            topupQuote: { days in try StorageQuote.decode(try await node.storageTopupQuote(days: days)) },
            topup: { amount in _ = try await node.storageTopupXdai(amountPerChunk: amount) },
            status: { try StorageStatus.decode(try await node.storageStatus()) },
            settlementDeposit: { try SettlementDeposit.decode(try await node.settlementDeposit()) },
            settlementTopup: { try SettlementDeposit.decode(try await node.settlementTopup()) },
            deployChequebook: { try await node.deployChequebook() }
        )
    }
}

/// A plan the user can pick: one of the stamp presets, sized the way
/// `StampMath` already does it (smallest depth whose effective volume
/// covers the advertised size).
struct StoragePlan: Identifiable, Equatable {
    let id: String
    let label: String
    let description: String
    let depth: UInt8
    let days: UInt64

    static let all: [StoragePlan] = StampService.presets.map { preset in
        StoragePlan(
            id: preset.id, label: preset.label, description: preset.description,
            depth: UInt8(clamping: StampMath.depthForSize(bytes: preset.sizeGB * 1_000_000_000)),
            days: UInt64(preset.durationDays)
        )
    }
    static let defaultIndex = StampService.defaultPresetIndex
}

/// AntDrive's onboarding as a state machine: pick a plan with an all-in
/// price, send plain xDAI to the node wallet, and let the node do the
/// chain work (swap, approve, createBatch, register, chequebook deploy
/// and deposit) once the quote reports sufficient funds. The same
/// machine extends a plan (`.extend`), where the quote and the call are
/// the top-up ones.
@MainActor
@Observable
final class StorageFundingController {
    enum Purchase: Equatable {
        case buy(StoragePlan)
        /// Extend the connected plan by `days`.
        case extend(days: UInt64)
    }

    enum Step: Equatable {
        case plan
        case payment
        case activating
        case done
    }

    /// Batches bought through this flow are immutable: a full mutable
    /// batch silently overwrites its oldest chunks, which is the wrong
    /// default for published sites.
    static let immutable = true
    static let paymentPoll: Duration = .seconds(6)

    private(set) var step: Step = .plan
    private(set) var purchase: Purchase?
    private(set) var quote: StorageQuote?
    private(set) var quotes: [String: StorageQuote] = [:]
    private(set) var isLoadingQuotes = false
    private(set) var error: String?
    /// A buy runs at most once per payment session; a failed activation
    /// drops back to `.payment` and needs a manual retry. v0.5.47 has no
    /// single-flight guard on the Rust side.
    private(set) var didAutoActivate = false
    private(set) var isActivating = false

    @ObservationIgnored private let ffi: StorageFFI
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Runs after a successful buy or extend (switch to light mode,
    /// refresh stamps).
    @ObservationIgnored var onActivated: (@MainActor (Purchase) async -> Void)?
    /// Runs after `setUpSettlement` deployed or adopted a chequebook.
    @ObservationIgnored var onSettlementSetUp: (@MainActor () async -> Void)?

    init(ffi: StorageFFI) {
        self.ffi = ffi
    }

    // MARK: - Plans

    /// Price every plan so the picker shows each all-in figure up front.
    func loadQuotes() async {
        isLoadingQuotes = true
        defer { isLoadingQuotes = false }
        await withTaskGroup(of: (String, StorageQuote?).self) { group in
            for plan in StoragePlan.all {
                group.addTask { @MainActor [ffi] in (plan.id, try? await ffi.quote(plan.depth, plan.days)) }
            }
            for await (id, quote) in group { if let quote { quotes[id] = quote } }
        }
        if quotes.isEmpty, step == .plan { error = "Couldn't reach the network to price plans." }
    }

    /// Start a purchase: a fresh quote, then the payment step.
    func start(_ purchase: Purchase) async {
        self.purchase = purchase
        error = nil
        didAutoActivate = false
        do {
            let fresh = try await requote(purchase)
            quote = fresh
            step = .payment
            if fresh.sufficientFunds { activateIfNeeded() } else { startPolling() }
        } catch {
            self.error = error.localizedDescription
            step = .plan
        }
    }

    func back() {
        pollTask?.cancel()
        pollTask = nil
        step = .plan
        purchase = nil
        quote = nil
        error = nil
        didAutoActivate = false
    }

    func reset() {
        back()
        quotes = [:]
    }

    // MARK: - Payment

    /// Re-quote every few seconds while the payment step is up: a
    /// re-quote re-reads the node wallet's balances, so when the transfer
    /// lands the plan activates by itself.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.paymentPoll)
                guard let self, !Task.isCancelled, self.step == .payment, let purchase = self.purchase else { return }
                guard let fresh = try? await self.requote(purchase) else { continue }
                self.quote = fresh
                if let plan = self.plan(of: purchase) { self.quotes[plan.id] = fresh }
                if fresh.sufficientFunds {
                    self.activateIfNeeded()
                    return
                }
            }
        }
    }

    /// Ask for a fresh quote now (pull to refresh, or after paying from
    /// the Freedom wallet).
    func refreshQuote() async {
        guard let purchase else { return }
        if let fresh = try? await requote(purchase) {
            quote = fresh
            if fresh.sufficientFunds, step == .payment { activateIfNeeded() }
        }
    }

    private func requote(_ purchase: Purchase) async throws -> StorageQuote {
        switch purchase {
        case .buy(let plan): try await ffi.quote(plan.depth, plan.days)
        case .extend(let days): try await ffi.topupQuote(days)
        }
    }

    private func plan(of purchase: Purchase) -> StoragePlan? {
        if case .buy(let plan) = purchase { return plan }
        return nil
    }

    // MARK: - Activation

    private func activateIfNeeded() {
        guard !didAutoActivate else { return }
        didAutoActivate = true
        Task { await activate() }
    }

    /// Run the buy / top-up once the node wallet holds enough. The
    /// manual "Activate" button calls this too (retry after a failure).
    func activate() async {
        guard !isActivating, let purchase, let quote else { return }
        isActivating = true
        pollTask?.cancel()
        pollTask = nil
        error = nil
        step = .activating
        defer { isActivating = false }
        do {
            switch purchase {
            case .buy(let plan):
                try await ffi.buy(plan.depth, quote.amountPerChunk, Self.immutable)
            case .extend:
                try await ffi.topup(quote.amountPerChunk)
            }
            step = .done
            log.info("storage \(String(describing: purchase), privacy: .public) activated")
            await onActivated?(purchase)
        } catch {
            log.warning("storage activation failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
            step = .payment
            didAutoActivate = true
            startPolling()
        }
    }

    // MARK: - Settlement deposit (existing installs)

    private(set) var deposit: SettlementDeposit?
    private(set) var isToppingUpDeposit = false
    private(set) var depositError: String?

    func refreshDeposit() async {
        deposit = try? await ffi.settlementDeposit()
    }

    /// Fund the chequebook's settlement deposit from xDAI the node holds.
    func topUpDeposit() async {
        guard !isToppingUpDeposit else { return }
        isToppingUpDeposit = true
        depositError = nil
        defer { isToppingUpDeposit = false }
        do {
            deposit = try await ffi.settlementTopup()
        } catch {
            depositError = error.localizedDescription
        }
    }

    private(set) var isSettingUpSettlement = false

    /// Settlement is off although the node holds batches (a deploy that
    /// ran out of gas, a reinstall whose old chequebook can't be
    /// rediscovered): deploy or adopt a chequebook from xDAI the node
    /// holds. Gateway start never does this on its own.
    func setUpSettlement() async {
        guard !isSettingUpSettlement else { return }
        isSettingUpSettlement = true
        depositError = nil
        defer { isSettingUpSettlement = false }
        do {
            _ = try await ffi.deployChequebook()
            await onSettlementSetUp?()
            deposit = try? await ffi.settlementDeposit()
        } catch {
            depositError = error.localizedDescription
        }
    }

    /// The plan ant stamps with, for deciding whether a batch can be
    /// extended through the node's xDAI top-up.
    func connectedPlanBatchID() async -> String? {
        (try? await ffi.status())?.batchID
    }
}
