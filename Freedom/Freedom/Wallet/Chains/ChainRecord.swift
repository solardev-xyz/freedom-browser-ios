import Foundation
import SwiftData

/// Persistent backing for a `Chain`. The runtime store (`ChainStore`)
/// vends `Chain` value types from these records so the wide call-site
/// surface that already passes `Chain` around is unaffected by the
/// move from compile-time `static let`s to user-editable data.
///
/// `isBuiltIn` gates deletion — mainnet must always exist (ENS and
/// Colibri are mainnet-only by protocol), and removing Gnosis would
/// silently break the embedded bee node's reads.
@Model
final class ChainRecord {
    /// EIP-155 chain ID, the natural unique key.
    @Attribute(.unique) var id: Int
    var displayName: String
    var nativeName: String
    var nativeSymbol: String
    var nativeDecimals: Int
    /// Stored as a string so a typo'd or never-validated URL surfaces at
    /// `Chain` materialization rather than blocking inserts. `URL.init`
    /// at read time is the conversion boundary.
    var explorerBase: String
    /// Whole-second target block time. `Duration.seconds(_:)` reconstructs
    /// the `Chain.pollInterval` at read time.
    var pollIntervalSeconds: Int
    /// Mainnet + Gnosis seed at first launch with this flag set; users
    /// can edit their RPC lists but can't delete the record.
    var isBuiltIn: Bool
    /// Ordered RPC provider URLs. Mirrors the `[String]` shape today's
    /// `ensPublicRpcProviders` carried so the seed/migration path is a
    /// straight copy. Normalization (trim + dedup + URL parse) stays in
    /// `EthereumRPCPool` — the record is just storage.
    var rpcURLs: [String]
    /// Stable display order in the chain list. Built-ins seed at 0/1;
    /// user-added chains take the next free slot.
    var sortOrder: Int

    init(
        id: Int,
        displayName: String,
        nativeName: String,
        nativeSymbol: String,
        nativeDecimals: Int,
        explorerBase: String,
        pollIntervalSeconds: Int,
        isBuiltIn: Bool,
        rpcURLs: [String],
        sortOrder: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.nativeName = nativeName
        self.nativeSymbol = nativeSymbol
        self.nativeDecimals = nativeDecimals
        self.explorerBase = explorerBase
        self.pollIntervalSeconds = pollIntervalSeconds
        self.isBuiltIn = isBuiltIn
        self.rpcURLs = rpcURLs
        self.sortOrder = sortOrder
    }
}
