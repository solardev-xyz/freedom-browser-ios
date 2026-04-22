import Foundation

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

    private let settings: SettingsStore
    private let clock: () -> Date

    private var shuffledOrder: [URL] = []
    private var quarantine: [URL: QuarantineEntry] = [:]

    init(settings: SettingsStore, clock: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.clock = clock
    }

    /// Providers in shuffled order, quarantined ones filtered out. Shuffle
    /// is cached across calls and only recomputed when the user's provider
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
        shuffledOrder = effective.shuffled()
        // Drop entries for providers the user just removed; stale failures
        // would otherwise keep a re-added URL quarantined when it shouldn't be.
        quarantine = quarantine.filter { live.contains($0.key) }
    }

    private func effectiveProviders() -> [URL] {
        let fromSettings = normalize(settings.ensPublicRpcProviders)
        // Fall back to defaults when the user's list is empty OR contains
        // only malformed entries — avoids silently breaking ENS resolution.
        return fromSettings.isEmpty
            ? normalize(SettingsStore.defaultPublicRpcProviders)
            : fromSettings
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
