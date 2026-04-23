import Foundation
import web3
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
    { url, _, _, _, _, _ in
        QuorumLeg.Outcome(url: url, kind: kinds[url] ?? .error(URLError(.badServerResponse)))
    }
}

/// Wrap raw bytes as an ABI-encoded `bytes` payload — matches the shape
/// the UR returns after one layer of unwrapping. Force-tries so encoding
/// failures fail the test loudly rather than silently corrupting assertions.
func abiEncodeBytes(_ payload: Data) -> Data {
    let encoder = ABIFunctionEncoder("_")
    try! encoder.encode(payload)
    let full = try! encoder.encoded()
    return Data(full.dropFirst(4))  // strip 4-byte method id
}

extension Data {
    /// Lowercase hex, no `0x` prefix. Test vectors in the BIP-39/BIP-32/
    /// Ethereum specs are presented without the prefix, so comparing against
    /// `.web3.hexString` (which prepends `0x`) would force a drop at every
    /// assertion site — this avoids that noise.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
