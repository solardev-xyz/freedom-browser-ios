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
        ChainRecord(
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
            pollInterval: .seconds(record.pollIntervalSeconds)
        )
    }

    private func save() { context.saveLogging("ChainStore", to: log) }
}
