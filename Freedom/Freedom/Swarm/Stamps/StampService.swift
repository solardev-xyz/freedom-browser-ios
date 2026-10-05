import BigInt
import Foundation
import SwarmKit

/// Owns the postage-stamp surface: list polling and the legacy extend
/// flows through bee's gateway. Buying (and extending the plan bought
/// that way) is node-side now — see `StorageFundingController`; the
/// presets here are what that flow prices. Mirrors desktop
/// `renderer/lib/wallet/stamp-manager.js` (presets, polling intervals)
/// so user expectations are portable across both apps.
@MainActor
@Observable
final class StampService {
    /// Extend (topup / dilute) state.
    enum ExtendState: Equatable {
        case idle
        case estimating
        /// Bee blocks on chain confirmation (~30 s, can stretch to
        /// minutes). UI keeps the button locked + spinner shown.
        case patching
        case completed
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

    /// Duration-extend presets — additive days. Default (index 1, +30
    /// days) lines up with the buy flow's "Small project" slot.
    static let durationExtendPresets: [DurationExtendPreset] = [
        .init(label: "+7 days", additionalDays: 7),
        .init(label: "+30 days", additionalDays: 30),
        .init(label: "+90 days", additionalDays: 90),
    ]
    static let defaultDurationExtendIndex = 1

    /// Size-extend presets — absolute target sizes. Same tier ladder
    /// as the buy presets so users see one mental model. UI disables
    /// rows ≤ batch's current size.
    static let sizeExtendPresets: [SizeExtendPreset] = [
        .init(label: "1 GB", sizeGB: 1),
        .init(label: "5 GB", sizeGB: 5),
        .init(label: "25 GB", sizeGB: 25),
    ]

    struct DurationExtendPreset: Equatable, Identifiable {
        let label: String
        let additionalDays: Int
        var id: String { label }
    }

    struct SizeExtendPreset: Equatable, Identifiable {
        let label: String
        let sizeGB: Int
        var id: String { label }
    }

    private(set) var stamps: [PostageBatch] = []
    /// True iff at least one of the current batches reports `usable`.
    /// Drives the publish-setup banner gate and step-4 status.
    private(set) var hasUsableStamps: Bool = false
    /// The running node's `/stamps` was read at least once. Until then an
    /// empty list means "not loaded yet", not "no storage" — the UI says
    /// it is loading instead of offering to buy storage. Reset whenever
    /// the node is not running.
    private(set) var hasLoaded = false
    private(set) var extendState: ExtendState = .idle
    /// Set after a node-side plan purchase: poll fast until the gateway
    /// lists a usable stamp (or the window passes).
    @ObservationIgnored private var awaitingPlanUntil: Date?

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let bee: BeeAPIClient
    @ObservationIgnored private let swarm: SwarmNode
    @ObservationIgnored private let settings: SettingsStore
    /// Short-lived cache of `/chainstate.currentPrice` so toggling
    /// extend presets doesn't pound bee with N back-to-back GETs. Price
    /// changes per ~5s block; 10s TTL keeps the quoted cost within the
    /// same block window the patch will land in.
    @ObservationIgnored private var cachedPrice: (value: Int, expiry: Date)?

    init(
        swarm: SwarmNode,
        settings: SettingsStore,
        bee: BeeAPIClient = BeeAPIClient()
    ) {
        self.swarm = swarm
        self.settings = settings
        self.bee = bee
    }

    /// A plan was just bought node-side (`StorageFundingController`);
    /// the gateway lists it once it restarts in light mode. Poll fast
    /// for a while so the stamps row and the setup checklist catch up
    /// without waiting for the idle tick.
    func expectNewPlan(window: TimeInterval = 600) {
        awaitingPlanUntil = Date().addingTimeInterval(window)
    }

    /// Idempotent — re-entry cancels the prior task. `activeInterval` is
    /// used while a fresh plan is expected (waiting for the batch to
    /// show up `usable`); `idleInterval` otherwise. Matches desktop's
    /// `USABLE_POLL_MS = 5000`. Until the first read succeeds the poll
    /// retries every `loadingInterval`, so the list appears as soon as
    /// the node answers rather than on the next idle tick.
    func start(
        activeIntervalSeconds: TimeInterval = 5,
        idleIntervalSeconds: TimeInterval = 30,
        loadingIntervalSeconds: TimeInterval = 2
    ) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStamps()
                let loading = await !(self?.hasLoaded ?? true)
                let active = await self?.shouldPollFast() ?? false
                let interval = loading ? loadingIntervalSeconds : (active ? activeIntervalSeconds : idleIntervalSeconds)
                try? await Task.sleep(nanoseconds: UInt64(max(1, interval) * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Lookup helper for views holding a `batchID` String — a successful
    /// extend triggers `refreshStamps`, which replaces the array, so
    /// pinned views read by id rather than holding a stale `PostageBatch`.
    func batch(id batchID: String) -> PostageBatch? {
        stamps.first(where: { $0.batchID == batchID })
    }

    /// Pull `/stamps`, normalize, update observable state. Bee returns
    /// 503 with "Node is syncing" until the chequebook subsystem is up;
    /// during that window we leave `stamps` empty and try again next
    /// tick.
    func refreshStamps() async {
        if swarm.status != .running, hasLoaded { hasLoaded = false }
        guard let batches = try? await fetchStamps() else { return }
        if !hasLoaded { hasLoaded = true }
        if batches != stamps { stamps = batches }
        let usable = batches.contains(where: { $0.usable })
        if usable != hasUsableStamps { hasUsableStamps = usable }
        if usable { awaitingPlanUntil = nil }
    }

    // MARK: - Extend flows (gateway; plans bought node-side extend via
    // `StorageFundingController`)

    /// Cost preview for `PATCH /stamps/topup`. The chequebook is charged
    /// `2^depth × additionalAmount` where `additionalAmount` is derived
    /// from `additionalDays` at the current network price.
    func estimateExtendDurationCost(
        batch: PostageBatch, additionalDays: Int
    ) async -> BigUInt? {
        guard let price = try? await fetchCurrentPrice() else { return nil }
        let additionalAmount = StampMath.amountForDuration(
            seconds: additionalDays * 86_400, pricePerBlock: price
        )
        return StampMath.costPlur(depth: batch.depth, amount: additionalAmount)
    }

    /// Cost preview for `PATCH /stamps/dilute`. No network call needed —
    /// bee uses the existing batch's `amount`. Returns `nil` if
    /// `targetSizeGB` would resolve to a depth ≤ current (UI should
    /// disable that preset row anyway, but estimator fails closed).
    func estimateExtendSizeCost(
        batch: PostageBatch, targetSizeGB: Int
    ) -> BigUInt? {
        let newDepth = StampMath.depthForSize(bytes: targetSizeGB * 1_000_000_000)
        guard newDepth > batch.depth, let oldAmount = batch.amountPlur else {
            return nil
        }
        return StampMath.diluteCostPlur(
            oldDepth: batch.depth, newDepth: newDepth, oldAmount: oldAmount
        )
    }

    /// Run topup state machine: re-fetch price, post `PATCH /stamps/topup`,
    /// refresh stamps. Charges xBZZ the node wallet holds, which a
    /// node-side plan purchase leaves none of — those plans extend via
    /// `ant_storage_topup_xdai` instead (`StorageFundingController`).
    func extendDuration(batch: PostageBatch, additionalDays: Int) async {
        extendState = .estimating
        let price: Int
        do {
            price = try await fetchCurrentPrice()
        } catch {
            extendState = .failed("Couldn't read network price.")
            return
        }
        let additionalAmount = StampMath.amountForDuration(
            seconds: additionalDays * 86_400, pricePerBlock: price
        )
        extendState = .patching
        do {
            try await bee.topUpStamp(
                batchID: batch.batchID, additionalAmount: additionalAmount
            )
            extendState = .completed
            await refreshStamps()
        } catch {
            extendState = .failed(error.localizedDescription)
        }
    }

    /// Run dilute state machine. `targetSizeGB` resolves to an absolute
    /// depth via `StampMath.depthForSize` — bee's gotcha (the endpoint
    /// takes absolute, not delta) is hidden behind this surface. Skips
    /// `.estimating` (unlike `extendDuration`) — depth resolution is
    /// synchronous, no network call to fail.
    func extendSize(batch: PostageBatch, targetSizeGB: Int) async {
        let newDepth = StampMath.depthForSize(bytes: targetSizeGB * 1_000_000_000)
        guard newDepth > batch.depth else {
            extendState = .failed("Target size must exceed current.")
            return
        }
        extendState = .patching
        do {
            try await bee.diluteStamp(batchID: batch.batchID, newDepth: newDepth)
            extendState = .completed
            await refreshStamps()
        } catch {
            extendState = .failed(error.localizedDescription)
        }
    }

    func resetExtendState() {
        extendState = .idle
    }

    // MARK: - Private

    private func shouldPollFast() -> Bool {
        guard let until = awaitingPlanUntil else { return false }
        if until < Date() {
            awaitingPlanUntil = nil
            return false
        }
        return true
    }

    private func fetchStamps() async throws -> [PostageBatch] {
        let dict = try await bee.getJSON("/stamps")
        guard let array = dict["stamps"] as? [[String: Any]] else { return [] }
        return array.compactMap(Self.parseBatch)
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
    /// required field is missing — caller drops malformed rows — and for
    /// a batch the chain says does not exist (`exists: false` /
    /// `batchTTL: -1`, bee's batchstore-miss shape): a never-created or
    /// evicted batch whose files the node still reloads at start until
    /// its own check unregisters it. It is not the user's storage.
    static func parseBatch(_ raw: [String: Any]) -> PostageBatch? {
        if raw["exists"] as? Bool == false { return nil }
        if let ttl = BeeAPIClient.intFromAnyJSON(raw["batchTTL"]), ttl < 0 { return nil }
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
            propagating: (raw["propagating"] as? Bool) ?? false,
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

    /// Stamp-bytes estimate for any feed-write surface (`createFeed`,
    /// `updateFeed`, `writeFeedEntry`). Feed writes always cost at
    /// least one chunk: createFeed / updateFeed have no caller-supplied
    /// payload but still write a single SOC; writeFeedEntry's wrap
    /// path can exceed one chunk because the original payload fans
    /// into a BMT tree under bee's `/bytes` path. `max` covers both.
    /// Pass `0` for create / update (no payload) and the actual
    /// payload size for `writeFeedEntry`.
    static func estimatedBytes(forFeedWrite payloadBytes: Int) -> Int {
        max(payloadBytes, SwarmSOC.maxChunkPayloadSize)
    }
}
