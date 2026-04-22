import Foundation
@testable import Freedom

final class MutableClock {
    var now: Date
    init(now: Date) { self.now = now }
    func advance(by interval: TimeInterval) { now.addTimeInterval(interval) }
}

actor ActorCallTracker {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}

/// A deterministic `LegRunner` driven by a per-URL outcome map. Any URL
/// not in the map returns a generic network error so missing entries are
/// obvious in test failures.
func makeLegRunner(_ kinds: [URL: QuorumLeg.Outcome.Kind]) -> QuorumWave.LegRunner {
    { url, _, _, _, _ in
        QuorumLeg.Outcome(url: url, kind: kinds[url] ?? .error(URLError(.badServerResponse)))
    }
}
