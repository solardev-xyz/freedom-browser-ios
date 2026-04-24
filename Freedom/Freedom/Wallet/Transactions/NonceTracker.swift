import Foundation

/// Per-(account, chain) pending-nonce cache. Two consecutive sends within
/// the same tab of RPC visibility would otherwise both fetch the same
/// `eth_getTransactionCount("pending")` value and collide. We fetch once,
/// then optimistically increment locally on successful broadcast; the next
/// RPC-fetched value either matches (good) or supersedes us (recover by
/// re-fetching).
@MainActor
final class NonceTracker {
    private struct Key: Hashable {
        let address: String
        let chainID: Int
    }

    private var cache: [Key: Int] = [:]
    private let rpc: WalletRPC

    init(rpc: WalletRPC) {
        self.rpc = rpc
    }

    /// Returns the next nonce to use. Fetches from chain on first call; on
    /// subsequent calls, reuses the cached value if it's ahead of what the
    /// chain reports (our pending tx hasn't propagated yet).
    func next(for address: String, on chain: Chain) async throws -> Int {
        let key = Key(address: address.lowercased(), chainID: chain.id)
        let fromChain = try await fetchPendingNonce(address: address, on: chain)
        if let cached = cache[key], cached > fromChain {
            return cached
        }
        cache[key] = fromChain
        return fromChain
    }

    /// Call after a successful `eth_sendRawTransaction` so the next `next(_:)`
    /// returns `usedNonce + 1` even if the node hasn't seen the pending tx yet.
    func markSent(address: String, on chain: Chain, usedNonce: Int) {
        let key = Key(address: address.lowercased(), chainID: chain.id)
        cache[key] = usedNonce + 1
    }

    /// Drop a cached value when a broadcast fails — forces the next `next(_:)`
    /// to re-read from chain, avoiding an off-by-one if we optimistically
    /// incremented for a tx that never landed.
    func invalidate(address: String, on chain: Chain) {
        cache.removeValue(forKey: Key(address: address.lowercased(), chainID: chain.id))
    }

    private func fetchPendingNonce(address: String, on chain: Chain) async throws -> Int {
        let hex = try await rpc.transactionCount(of: address, on: chain)
        return Hex.int(hex) ?? 0
    }
}
