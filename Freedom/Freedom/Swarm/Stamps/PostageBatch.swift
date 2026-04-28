import Foundation

/// Normalized model for a Bee postage batch. Maps from `/stamps` JSON.
/// Field meanings match desktop `stamp-service.js:normalizeBatch`; we
/// derive `effectiveBytes` from depth via `StampMath` rather than
/// trusting bee's reported size (bee returns 0 in some early states).
struct PostageBatch: Equatable, Identifiable {
    /// 32-byte hex (no 0x prefix per bee's convention). Used as `id`.
    let batchID: String
    /// Bee marks a batch usable once enough on-chain confirmations have
    /// accrued (~5–10s after purchase). Until then the UI greys it out.
    let usable: Bool
    /// Fraction in `[0, 1]`: utilization / 2^(depth − bucketDepth).
    let usage: Double
    /// Effective storage in bytes derived from `depth`, the source of
    /// truth for "how much can I still publish".
    let effectiveBytes: Int
    /// Time-to-live in seconds. 0 means expired or unknown.
    let ttlSeconds: Int
    /// True when `immutableFlag == false`. Not currently surfaced.
    let isMutable: Bool
    let depth: Int
    /// PLUR per chunk per block, kept as string to avoid threading
    /// `BigUInt` through the model.
    let amount: String
    let label: String?

    var id: String { batchID }
    var usagePercent: Int { Int((usage * 100).rounded()) }
}
