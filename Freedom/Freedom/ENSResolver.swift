import Foundation
import web3

@MainActor
@Observable
final class ENSResolver {
    // DAO-owned proxy so future UR impl upgrades don't require a client change.
    // https://docs.ens.domains/resolvers/universal/
    static let universalResolverAddress = "0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe"

    private let pool: EthereumRPCPool

    init(pool: EthereumRPCPool) {
        self.pool = pool
    }

    func resolveContent(_ name: String) async throws -> ENSResolvedContent {
        throw ENSResolutionError.notImplemented
    }
}
