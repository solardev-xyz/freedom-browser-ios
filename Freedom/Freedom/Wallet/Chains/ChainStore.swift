import Foundation
import Observation
import OSLog
import SwiftData

private let log = Logger(subsystem: "com.browser.Freedom", category: "ChainStore")

/// Runtime store of `ChainRecord`s. Vends `Chain` value types from the
/// SwiftData backing so call sites that already pass `Chain` around keep
/// working; mutation goes through the store so changes propagate.
///
/// Seeds mainnet + Gnosis on first launch. If the user had customized
/// `settings.ensPublicRpcProviders` before the chain store existed, those
/// URLs are migrated into the mainnet record exactly once — gated by the
/// `chainStoreMigrated` marker so a later edit to the mainnet record
/// can't be clobbered by a wipe-and-reseed.
@MainActor
@Observable
final class ChainStore {
    /// Bumped on every mutation. `allChains()` and `chain(id:)` read this
    /// so SwiftUI views observing the store re-evaluate after add /
    /// update / delete — the `ChainRecord`s are SwiftData-managed and
    /// don't drive @Observable on their own.
    private(set) var version: Int = 0

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let settings: SettingsStore

    init(context: ModelContext, settings: SettingsStore) {
        self.context = context
        self.settings = settings
        seedAndMigrateIfNeeded()
        refreshSeedsIfNeeded()
    }

    // MARK: - Reads

    /// All chains in display order. Built-ins seed first (Gnosis sortOrder
    /// 0, Mainnet 1) so the chain picker matches today's `Chain.all` order.
    func allChains() -> [Chain] {
        _ = version
        return records().compactMap(chain(from:))
    }

    func chain(id: Int) -> Chain? {
        _ = version
        return record(id: id).flatMap(chain(from:))
    }

    /// Raw RPC URL strings for a chain. The `EthereumRPCPool` closes over
    /// this so its URL source moves with user edits to the record.
    func rpcURLs(forChainID id: Int) -> [String] {
        _ = version
        return record(id: id)?.rpcURLs ?? []
    }

    /// True for an RPC URL the user added themselves, as opposed to one
    /// the chain shipped with (its `defaultRPCURLs` snapshot).
    func isUserAddedRPCURL(_ url: String, chainID id: Int) -> Bool {
        let key = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, rpcURLs(forChainID: id).contains(where: { $0.lowercased() == key }) else { return false }
        return !defaultRPCURLs(forChainID: id).contains { $0.lowercased() == key }
    }

    /// The RPC URLs a chain shipped with. Built-ins: the current seed;
    /// custom chains: the list they were added with.
    func defaultRPCURLs(forChainID id: Int) -> [String] {
        _ = version
        return record(id: id)?.defaultRPCURLs ?? []
    }

    /// The user's own endpoints for a chain, in list order.
    func userAddedRPCURLs(forChainID id: Int) -> [String] {
        rpcURLs(forChainID: id).filter { isUserAddedRPCURL($0, chainID: id) }
    }

    // MARK: - Routing policy

    /// The chain-data routing policy for a chain. Orders come from the
    /// record (empty = desktop default). Mainnet's quorum, prover and ZK
    /// settings are the ENS keys in `SettingsStore` — one source of
    /// truth shared by name resolution and the chain-data router — and
    /// the record fields hold them for every other chain.
    func policy(forChainID id: Int) -> ChainAccessPolicy {
        _ = version
        var policy = ChainAccessPolicy.default(forChainID: id)
        guard let record = record(id: id) else { return policy }
        let readOrder = record.readOrder.compactMap(ChainSource.init(rawValue:))
        if !readOrder.isEmpty { policy.readOrder = readOrder }
        let broadcastOrder = record.broadcastOrder.compactMap(ChainSource.init(rawValue:))
        if !broadcastOrder.isEmpty { policy.broadcastOrder = broadcastOrder }
        if id == Chain.mainnetID {
            policy.quorumK = settings.ensQuorumK
            policy.quorumM = settings.ensQuorumM
            policy.quorumTimeoutMs = settings.ensQuorumTimeoutMs
            policy.proverURL = settings.ensColibriProverUrl
            policy.zkProof = settings.ensColibriZkProof
        } else {
            policy.quorumK = record.quorumK
            policy.quorumM = record.quorumM
            policy.quorumTimeoutMs = record.quorumTimeoutMs
            policy.proverURL = record.proverURL
            policy.zkProof = record.zkProof
        }
        return policy
    }

    /// Persist a policy. Orders are stored as given (the router sanitizes
    /// on read); quorum numbers are clamped so the settings page cannot
    /// store an impossible M > K.
    func updatePolicy(forChainID id: Int, _ policy: ChainAccessPolicy) {
        guard let record = record(id: id) else { return }
        let sanitized = policy.sanitized(forChainID: id)
        record.readOrder = policy.readOrder.map(\.rawValue)
        record.broadcastOrder = policy.broadcastOrder.map(\.rawValue)
        if id == Chain.mainnetID {
            settings.ensQuorumK = sanitized.quorumK
            settings.ensQuorumM = sanitized.quorumM
            settings.ensQuorumTimeoutMs = sanitized.quorumTimeoutMs
            settings.ensColibriProverUrl = sanitized.proverURL ?? ""
            settings.ensColibriZkProof = sanitized.zkProof
        } else {
            record.quorumK = sanitized.quorumK
            record.quorumM = sanitized.quorumM
            record.quorumTimeoutMs = sanitized.quorumTimeoutMs
            record.proverURL = sanitized.proverURL ?? ""
            record.zkProof = sanitized.zkProof
        }
        save()
        version += 1
    }

    // MARK: - Writes

    enum AddChainError: Error {
        case duplicateID(Int)
    }

    func updateRPCURLs(forChainID id: Int, _ urls: [String]) {
        guard let record = record(id: id) else { return }
        record.rpcURLs = urls
        save()
        version += 1
    }

    /// Back to the shipped list (the "Public RPCs"), dropping the user's
    /// own endpoints.
    func resetRPCURLs(forChainID id: Int) {
        guard let record = record(id: id), !record.defaultRPCURLs.isEmpty else { return }
        record.rpcURLs = record.defaultRPCURLs
        save()
        version += 1
    }

    /// Insert a user-added chain. `isBuiltIn` is hardcoded `false` — the
    /// two protocol-pinned chains can only ever be added via seeding.
    func addChain(
        id: Int,
        displayName: String,
        nativeName: String,
        nativeSymbol: String,
        nativeDecimals: Int,
        explorerBase: String,
        pollIntervalSeconds: Int,
        rpcURLs: [String]
    ) throws {
        if record(id: id) != nil { throw AddChainError.duplicateID(id) }
        let record = ChainRecord(
            id: id,
            displayName: displayName,
            nativeName: nativeName,
            nativeSymbol: nativeSymbol,
            nativeDecimals: nativeDecimals,
            explorerBase: explorerBase,
            pollIntervalSeconds: pollIntervalSeconds,
            isBuiltIn: false,
            rpcURLs: rpcURLs,
            sortOrder: nextSortOrder()
        )
        // What the chain was added with counts as shipped: the user's
        // later additions are the ones tried first and labelled theirs.
        record.defaultRPCURLs = rpcURLs
        context.insert(record)
        save()
        version += 1
    }

    /// No-op on built-ins. Settings UI should hide the delete affordance,
    /// but the guard here is the canonical safety net.
    func deleteChain(id: Int) {
        guard let record = record(id: id), !record.isBuiltIn else { return }
        context.delete(record)
        save()
        version += 1
    }

    // MARK: - Seeding & migration

    private func seedAndMigrateIfNeeded() {
        let existing = records()
        guard existing.isEmpty else { return }

        // Mainnet picks up the user's customized `ensPublicRpcProviders`
        // exactly once, gated by the marker — so a future wipe-and-reseed
        // won't re-import a potentially-stale UserDefaults list and clobber
        // edits the user made in `ChainStore` itself. An empty settings
        // list is never imported: it would leave mainnet with no providers
        // and break ENS / wallet RPC on first launch.
        let candidate = settings.ensPublicRpcProviders
        let shouldImportCustomMainnet = !settings.chainStoreMigrated
            && !candidate.isEmpty
            && candidate != SettingsStore.defaultPublicRpcProviders
        let mainnetURLs = shouldImportCustomMainnet
            ? candidate
            : SettingsStore.defaultPublicRpcProviders

        context.insert(seedRecord(
            template: .gnosis,
            rpcURLs: ChainRegistry.gnosisURLs.map(\.absoluteString),
            sortOrder: 0
        ))
        context.insert(seedRecord(
            template: .mainnet,
            rpcURLs: mainnetURLs,
            sortOrder: 1
        ))
        save()

        if !settings.chainStoreMigrated {
            settings.chainStoreMigrated = true
            log.info(
                "[chainstore] seeded; migrated mainnet from settings=\(shouldImportCustomMainnet, privacy: .public)"
            )
        } else {
            log.info("[chainstore] reseeded (post-wipe); skipping settings import")
        }
        version += 1
    }

    private func seedRecord(template: Chain, rpcURLs: [String], sortOrder: Int) -> ChainRecord {
        let record = ChainRecord(
            id: template.id,
            displayName: template.displayName,
            nativeName: template.nativeName,
            nativeSymbol: template.nativeSymbol,
            nativeDecimals: template.nativeDecimals,
            explorerBase: template.explorerBase.absoluteString,
            pollIntervalSeconds: Int(template.pollInterval.components.seconds),
            isBuiltIn: true,
            rpcURLs: rpcURLs,
            sortOrder: sortOrder
        )
        record.defaultRPCURLs = Self.seedURLs(forChainID: template.id) ?? rpcURLs
        return record
    }

    /// The current shipped list for a built-in chain.
    static func seedURLs(forChainID id: Int) -> [String]? {
        switch id {
        case Chain.mainnetID: return SettingsStore.defaultPublicRpcProviders
        case Chain.gnosisID: return ChainRegistry.gnosisURLs.map(\.absoluteString)
        default: return nil
        }
    }

    /// URLs that were a seed at some point and are not one now.
    private static func retiredSeedURLs(forChainID id: Int) -> Set<String> {
        let current = Set((seedURLs(forChainID: id) ?? []).map { $0.lowercased() })
        let everShipped: Set<String>
        switch id {
        case Chain.mainnetID: everShipped = SettingsStore.legacyPublicRpcProviders
        case Chain.gnosisID: everShipped = ChainRegistry.legacyGnosisURLs
        default: everShipped = []
        }
        return Set(everShipped.map { $0.lowercased() }).subtracting(current)
    }

    /// Bring built-in records seeded by an older build up to the current
    /// seed: the snapshot is refreshed, retired public endpoints (dead
    /// ones, keyed-only ones) are dropped, new ones added, and the user's
    /// own endpoints stay first. A record whose list contains no shipped
    /// endpoint at all was deliberately made private — it keeps its list
    /// and only gets the snapshot. Custom chains get their snapshot
    /// backfilled from their current list.
    private func refreshSeedsIfNeeded() {
        var changed = false
        for record in records() {
            guard let seed = Self.seedURLs(forChainID: record.id) else {
                if record.defaultRPCURLs.isEmpty {
                    record.defaultRPCURLs = record.rpcURLs
                    changed = true
                }
                continue
            }
            guard record.defaultRPCURLs != seed else { continue }
            let seedKeys = Set(seed.map { $0.lowercased() })
            let retired = Self.retiredSeedURLs(forChainID: record.id)
            let oldSnapshot = Set(record.defaultRPCURLs.map { $0.lowercased() })
            let shippedKeys = seedKeys.union(retired).union(oldSnapshot)
            let hadShipped = record.rpcURLs.contains { shippedKeys.contains($0.lowercased()) }
            if hadShipped {
                let mine = record.rpcURLs.filter { !shippedKeys.contains($0.lowercased()) }
                record.rpcURLs = mine + seed
                log.info("[chainstore] refreshed chain \(record.id) seed: kept \(mine.count) user endpoints")
            }
            record.defaultRPCURLs = seed
            changed = true
        }
        if changed {
            save()
            version += 1
        }
    }

    // MARK: - Internals

    /// Fetch-all + Swift filter mirrors `BookmarkStore`'s pattern —
    /// `#Predicate` equality has known sharp edges under SwiftData on iOS
    /// 17, and chain counts stay tiny so the cost is negligible.
    private func records() -> [ChainRecord] {
        let descriptor = FetchDescriptor<ChainRecord>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func record(id: Int) -> ChainRecord? {
        records().first { $0.id == id }
    }

    private func nextSortOrder() -> Int {
        (records().map(\.sortOrder).max() ?? -1) + 1
    }

    private func chain(from record: ChainRecord) -> Chain? {
        guard let explorer = URL(string: record.explorerBase) else { return nil }
        return Chain(
            id: record.id,
            displayName: record.displayName,
            explorerBase: explorer,
            nativeName: record.nativeName,
            nativeSymbol: record.nativeSymbol,
            nativeDecimals: record.nativeDecimals,
            pollInterval: .seconds(record.pollIntervalSeconds),
            isBuiltIn: record.isBuiltIn
        )
    }

    private func save() { context.saveLogging("ChainStore", to: log) }
}
