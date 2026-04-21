import Foundation

enum SwarmRef {
    /// A Swarm reference: 64 hex chars (32-byte plain) or 128 hex chars (64-byte encrypted).
    static func isValid(_ s: some StringProtocol) -> Bool {
        (s.count == 64 || s.count == 128) && s.allSatisfy(\.isHexDigit)
    }

    /// Generic hex check of a specific length. Used for non-ref Bee API segments
    /// like 40-hex owners and 64-hex topics.
    static func isHex(_ s: some StringProtocol, length: Int) -> Bool {
        s.count == length && s.allSatisfy(\.isHexDigit)
    }
}
