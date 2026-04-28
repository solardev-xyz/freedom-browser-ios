import BigInt
import Foundation
import SwarmKit

/// Owns the postage-stamp surface: list polling, cost estimation, and
/// the buy flow's state machine. Mirrors desktop
/// `renderer/lib/wallet/stamp-manager.js` end-to-end (presets,
/// transitions, polling intervals) so user expectations are portable
/// across both apps.
@MainActor
@Observable
final class StampService {
    enum BuyState: Equatable {
        case idle
        /// Brief window while we re-fetch `/chainstate.currentPrice`
        /// before posting the buy. UI keeps the button locked.
        case estimating
        case purchasing
        case waitingForUsable(batchID: String)
        case usable
        case failed(String)
    }

    /// Preset cards, copied verbatim from desktop
    /// `stamp-manager.js:14-19`. Default is index 1 (Small project).
    static let presets: [Preset] = [
        Preset(label: "Try it out",    sizeGB: 1, durationDays: 7,
               description: "1 GB for 7 days"),
        Preset(label: "Small project", sizeGB: 1, durationDays: 30,
               description: "1 GB for 30 days"),
        Preset(label: "Standard",      sizeGB: 5, durationDays: 30,
               description: "5 GB for 30 days"),
    ]
    static let defaultPresetIndex = 1

    struct Preset: Equatable, Identifiable {
        let label: String
        let sizeGB: Int
        let durationDays: Int
        let description: String
        var id: String { label }
    }

    private(set) var stamps: [PostageBatch] = []
    /// True iff at least one of the current batches reports `usable`.
    /// Drives the publish-setup banner gate and step-4 status.
    private(set) var hasUsableStamps: Bool = false
    private(set) var buyState: BuyState = .idle

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let bee: BeeAPIClient
    @ObservationIgnored private let swarm: SwarmNode
    @ObservationIgnored private let settings: SettingsStore
    /// Set via `attach(walletInfo:)` so the stamp-buy auto-deposit can
    /// trigger an immediate balance refresh. `weak` because both
    /// services are owned by `FreedomApp` — no need to keep it alive.
    @ObservationIgnored private weak var walletInfo: BeeWalletInfo?
    /// Short-lived cache of `/chainstate.currentPrice`. Used by both
    /// `estimateCost` (called per preset toggle) and `buy` so toggling
    /// presets in the purchase form doesn't pound bee with N back-to-
    /// back GETs. Price changes per ~5s block; 10s TTL keeps quoted
    /// cost within the same block window the buy will land in.
    @ObservationIgnored private var cachedPrice: (value: Int, expiry: Date)?

    /// Floor balance we keep the chequebook topped up to after every
    /// stamp purchase. 0.1 xBZZ in PLUR (1 BZZ = 1e16 PLUR) matches
    /// desktop's `AUTO_DEPOSIT_BZZ` constant. `10^15` rather than a
    /// digit literal so miscounted zeros surface as a build error.
    private static let chequebookFloorPlur: BigUInt = BigUInt(10).power(15)

    init(
        swarm: SwarmNode,
        settings: SettingsStore,
        bee: BeeAPIClient = BeeAPIClient()
    ) {
        self.swarm = swarm
        self.settings = settings
        self.bee = bee
    }

    /// Inject the wallet-info service so the chequebook auto-deposit
    /// can trigger a fresh balance read once the deposit tx confirms.
    /// `weak` to avoid the StampService↔BeeWalletInfo retain cycle if
    /// the latter ever holds a reference back.
    func attach(walletInfo: BeeWalletInfo) {
        self.walletInfo = walletInfo
    }

    /// Idempotent — re-entry cancels the prior task. `activeInterval` is
    /// used while a purchase is mid-flight (waiting for the batch to
    /// flip `usable`); `idleInterval` otherwise. Matches desktop's
    /// `USABLE_POLL_MS = 5000`.
    func start(
        activeIntervalSeconds: TimeInterval = 5,
        idleIntervalSeconds: TimeInterval = 30
    ) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStamps()
                let active = await self?.shouldPollFast() ?? false
                let interval = active ? activeIntervalSeconds : idleIntervalSeconds
                try? await Task.sleep(nanoseconds: UInt64(max(1, interval) * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Pull `/stamps`, normalize, update observable state. Bee returns
    /// 503 with "Node is syncing" until the chequebook subsystem is up;
    /// during that window we leave `stamps` empty and try again next
    /// tick.
    func refreshStamps() async {
        guard settings.beeNodeMode == .light else {
            if !stamps.isEmpty { stamps = [] }
            if hasUsableStamps { hasUsableStamps = false }
            return
        }
        guard let batches = try? await fetchStamps() else { return }
        if batches != stamps { stamps = batches }
        let usable = batches.contains(where: { $0.usable })
        if usable != hasUsableStamps { hasUsableStamps = usable }
        // Buy-flow self-completion: if we were waiting for a specific
        // batchID and it now reports usable, transition.
        if case .waitingForUsable(let id) = buyState,
           batches.contains(where: { $0.batchID == id && $0.usable }) {
            buyState = .usable
        }
    }

    // MARK: - Cost estimation

    /// Estimate the cost of a preset using bee's `/chainstate.currentPrice`.
    /// Returns nil if chainstate is unreachable or has no price field.
    func estimateCost(for preset: Preset) async -> BigUInt? {
        guard let price = try? await fetchCurrentPrice() else { return nil }
        let depth = StampMath.depthForSize(bytes: preset.sizeGB * 1_000_000_000)
        let seconds = preset.durationDays * 86_400
        let amount = StampMath.amountForDuration(seconds: seconds, pricePerBlock: price)
        return StampMath.costPlur(depth: depth, amount: amount)
    }

    // MARK: - Buy flow

    /// Run the full buy state machine. Builds depth+amount from the
    /// preset, posts to bee (blocks until tx confirms — typically
    /// 30s–2min on Gnosis), then transitions to `waitingForUsable`.
    /// `refreshStamps()` finishes the state machine when the new batch
    /// flips `usable`.
    func buy(preset: Preset) async {
        buyState = .estimating
        let price: Int
        do {
            price = try await fetchCurrentPrice()
        } catch {
            buyState = .failed("Couldn't read network price.")
            return
        }
        let depth = StampMath.depthForSize(bytes: preset.sizeGB * 1_000_000_000)
        let seconds = preset.durationDays * 86_400
        let amount = StampMath.amountForDuration(seconds: seconds, pricePerBlock: price)
        buyState = .purchasing
        do {
            let batchID = try await postBuy(amount: amount, depth: depth)
            buyState = .waitingForUsable(batchID: batchID)
            await refreshStamps()
            // Keep the chequebook at its floor for SWAP bandwidth pay-
            // ments. Fire-and-forget so the .usable transition doesn't
            // wait on the deposit tx (~30s on Gnosis); polling picks
            // up `.usable` independently.
            Task { [weak self] in
                await self?.topUpChequebookIfBelowFloor()
            }
        } catch {
            buyState = .failed(error.localizedDescription)
        }
    }

    /// Reset the state machine back to `.idle`. Called when the user
    /// dismisses a failed-purchase alert, or returns to the idle form
    /// after a successful purchase.
    func resetBuyState() {
        buyState = .idle
    }

    // MARK: - Private

    private func shouldPollFast() -> Bool {
        if case .waitingForUsable = buyState { return true }
        return false
    }

    private func fetchStamps() async throws -> [PostageBatch] {
        let dict = try await bee.getJSON("/stamps")
        guard let array = dict["stamps"] as? [[String: Any]] else { return [] }
        return array.compactMap(Self.parseBatch)
    }

    /// `POST /stamps/{amount}/{depth}` — bee's stamp purchase. Bee
    /// blocks the response until the on-chain tx confirms. Generous
    /// timeout (5min) to match desktop's `BUY_TIMEOUT_MS`.
    private func postBuy(amount: BigUInt, depth: Int) async throws -> String {
        let dict = try await bee.postJSON("/stamps/\(amount)/\(depth)", timeout: 300)
        guard let id = dict["batchID"] as? String else {
            throw BeeAPIClient.Error.malformedResponse
        }
        return id
    }

    /// Read `/chequebook/balance.availableBalance` and, if it's below
    /// our 0.1 xBZZ floor, deposit the shortfall from the node wallet.
    /// Silent on failure (no surfaced error) — the chequebook can also
    /// be topped up manually later via the (future) wallet UI; an
    /// auto-deposit is best-effort plumbing, not user-visible state.
    private func topUpChequebookIfBelowFloor() async {
        guard let dict = try? await bee.getJSON("/chequebook/balance"),
              let availableStr = dict["availableBalance"] as? String,
              let available = BigUInt(availableStr, radix: 10) else {
            return
        }
        let floor = Self.chequebookFloorPlur
        guard available < floor else { return }
        let shortfall = floor - available
        // Skip if the node wallet can't cover the shortfall — surfacing
        // a dialog mid-stamp-purchase would be jarring; user can top
        // up manually later.
        guard let walletDict = try? await bee.getJSON("/wallet"),
              let walletStr = walletDict["bzzBalance"] as? String,
              let walletBzz = BigUInt(walletStr, radix: 10),
              walletBzz >= shortfall else {
            return
        }
        // Bee blocks until the on-chain deposit tx confirms — same 5min
        // budget as the stamp-purchase POST.
        _ = try? await bee.postJSON(
            "/chequebook/deposit",
            query: ["amount": shortfall.description],
            timeout: 300
        )
        // Snap balances fresh so the user doesn't have to wait for the
        // 30s polling tick to see the chequebook update.
        await walletInfo?.refresh()
    }

    private func fetchCurrentPrice() async throws -> Int {
        if let cached = cachedPrice, cached.expiry > Date() {
            return cached.value
        }
        let dict = try await bee.getJSON("/chainstate")
        guard let raw = dict["currentPrice"],
              let price = BeeAPIClient.intFromAnyJSON(raw) else {
            throw BeeAPIClient.Error.malformedResponse
        }
        cachedPrice = (price, Date().addingTimeInterval(10))
        return price
    }

    /// Map a `/stamps` array entry to our model. Returns nil if any
    /// required field is missing — caller drops malformed rows.
    private static func parseBatch(_ raw: [String: Any]) -> PostageBatch? {
        guard let id = raw["batchID"] as? String,
              let depth = BeeAPIClient.intFromAnyJSON(raw["depth"]),
              let bucketDepth = BeeAPIClient.intFromAnyJSON(raw["bucketDepth"]),
              let utilization = BeeAPIClient.intFromAnyJSON(raw["utilization"]),
              let usable = raw["usable"] as? Bool else {
            return nil
        }
        let amount = (raw["amount"] as? String) ?? "0"
        let immutable = (raw["immutableFlag"] as? Bool) ?? false
        let label = raw["label"] as? String
        let batchTTL = BeeAPIClient.intFromAnyJSON(raw["batchTTL"]) ?? 0
        // bee-js's `getStampUsage`: utilization / 2^(depth - bucketDepth).
        let denom = max(1.0, pow(2.0, Double(depth - bucketDepth)))
        let usage = max(0.0, min(1.0, Double(utilization) / denom))
        return PostageBatch(
            batchID: id,
            usable: usable,
            usage: usage,
            effectiveBytes: StampMath.effectiveBytes(forDepth: depth),
            ttlSeconds: max(0, batchTTL),
            isMutable: !immutable,
            depth: depth,
            amount: amount,
            label: label
        )
    }

    // MARK: - Batch selection

    /// Headroom multiplier applied on top of the dapp-supplied byte
    /// count. Covers the chunk-encoding overhead bee adds at upload
    /// time — without it, an upload that just barely fits a batch's
    /// remaining capacity gets rejected mid-stream. Same `1.5` desktop
    /// uses (`SIZE_SAFETY_MARGIN`).
    static let sizeSafetyMargin: Double = 1.5

    /// First-fit usable batch with at least `bytes × sizeSafetyMargin`
    /// remaining capacity, longest-TTL among qualifiers as the
    /// tiebreaker. Mirrors desktop's `selectBestBatch`.
    static func selectBestBatch(
        forBytes bytes: Int, in stamps: [PostageBatch]
    ) -> PostageBatch? {
        let required = Double(bytes) * sizeSafetyMargin
        return stamps
            .filter { $0.usable }
            .filter { Double($0.effectiveBytes) * (1.0 - $0.usage) >= required }
            .max(by: { $0.ttlSeconds < $1.ttlSeconds })
    }
}
