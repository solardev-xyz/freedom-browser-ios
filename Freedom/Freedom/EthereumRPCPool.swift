import Foundation

/// Per-chain RPC provider pool with shuffle + exponential-backoff
/// quarantine. URL source is closure-injected so the pool stays
/// decoupled from the chain backing — production wires the closure
/// through `ChainStore`; tests use a closure reading from a
/// `SettingsStore` or any other source.
@MainActor
final class EthereumRPCPool {
    private struct QuarantineEntry {
        var failures: Int
        var cooldownUntil: Date
    }

    // 60s × 2^(failures-1), capped at 10min. In-memory only; reset on
    // process restart or explicit invalidate() after settings edits.
    static let quarantineBase: TimeInterval = 60
    static let quarantineMax: TimeInterval = 600

    /// EIP-155 chain ID this pool serves. Surfaced so the registry can
    /// route writes (`markSuccess`/`markFailure`) without an extra map.
    let chainID: Int

    private let urlSource: @MainActor () -> [String]
    private let clock: () -> Date
    private let orderer: ([URL]) -> [URL]

    private var shuffledOrder: [URL] = []
    private var quarantine: [URL: QuarantineEntry] = [:]

    init(
        chainID: Int,
        urlSource: @escaping @MainActor () -> [String],
        clock: @escaping () -> Date = Date.init,
        orderer: @escaping ([URL]) -> [URL] = { $0.shuffled() }
    ) {
        self.chainID = chainID
        self.urlSource = urlSource
        self.clock = clock
        self.orderer = orderer
    }

    /// Providers in shuffled order, quarantined ones filtered out. Shuffle
    /// is cached across calls and only recomputed when the URL source's
    /// list changes; expired quarantine entries evict lazily here.
    func availableProviders() -> [URL] {
        refreshShuffleIfNeeded()
        let now = clock()
        return shuffledOrder.filter { url in
            guard let entry = quarantine[url] else { return true }
            if now >= entry.cooldownUntil {
                quarantine.removeValue(forKey: url)
                return true
            }
            return false
        }
    }

    func markSuccess(_ url: URL) {
        quarantine.removeValue(forKey: url)
    }

    func markFailure(_ url: URL) {
        let failures = (quarantine[url]?.failures ?? 0) + 1
        let cooldown = min(
            Self.quarantineBase * pow(2, Double(failures - 1)),
            Self.quarantineMax
        )
        quarantine[url] = QuarantineEntry(
            failures: failures,
            cooldownUntil: clock().addingTimeInterval(cooldown)
        )
    }

    /// Clear shuffle cache + quarantine. Call after a settings edit so a
    /// provider the user just re-enabled gets a fresh chance.
    func invalidate() {
        shuffledOrder = []
        quarantine.removeAll()
    }

    private func refreshShuffleIfNeeded() {
        let effective = effectiveProviders()
        let live = Set(effective)
        if live == Set(shuffledOrder) { return }
        shuffledOrder = orderer(effective)
        // Drop entries for providers the user just removed; stale failures
        // would otherwise keep a re-added URL quarantined when it shouldn't be.
        quarantine = quarantine.filter { live.contains($0.key) }
    }

    private func effectiveProviders() -> [URL] {
        let normalized = normalize(urlSource())
        // Mainnet falls back to the bundled defaults if its source returns
        // an empty list — keeps ENS / wallet alive in case a migration
        // edge case (or a future Phase 2 UI bug) leaves the mainnet record
        // cleared. For non-mainnet chains, empty is reported truthfully
        // and `WalletRPC.fanOut` throws `noProviders`; the user's per-
        // chain editor is the right place to fix it.
        if normalized.isEmpty && chainID == Chain.mainnetID {
            return normalize(SettingsStore.defaultPublicRpcProviders)
        }
        return normalized
    }

    private func normalize(_ raw: [String]) -> [URL] {
        var seen: Set<String> = []
        var out: [URL] = []
        for item in raw {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key), let url = URL(string: trimmed) else { continue }
            seen.insert(key)
            out.append(url)
        }
        return out
    }
}
