import SwiftUI

/// Display helpers shared across stamp UI (`StampsView`, `StampDetailView`,
/// `StampExtendView`). Keeps the bee-js parity facts — 1000-base bytes,
/// matching unit copy — pinned to one location so a single edit propagates.
enum StampFormatting {
    /// Bee uses 1000-base units (consistent with bee-js / Swarm papers
    /// on theoretical/effective capacity). 1 GB = 1e9, not 2^30.
    /// `ByteCountFormatter` defaults to 1024-base, which would diverge
    /// from desktop's display for the same depth.
    static func bytes(_ bytes: Int) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return "\(bytes) B"
    }

    static func ttl(_ seconds: Int) -> String {
        if seconds <= 0 { return "—" }
        let days = seconds / 86_400
        if days > 0 { return "\(days) day\(days == 1 ? "" : "s")" }
        let hours = seconds / 3600
        if hours > 0 { return "\(hours) hour\(hours == 1 ? "" : "s")" }
        let mins = max(1, seconds / 60)
        return "\(mins) minute\(mins == 1 ? "" : "s")"
    }
}

/// Capsule badge shown on every stamp card / detail header — green
/// "Usable" or orange "Not usable" depending on bee's `usable` flag.
@MainActor
struct StampStatusBadge: View {
    let usable: Bool

    var body: some View {
        Text(usable ? "Usable" : "Not usable")
            .font(.caption2).fontWeight(.semibold)
            .foregroundStyle(usable ? Color.green : Color.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((usable ? Color.green : Color.orange).opacity(0.15))
            .clipShape(Capsule())
    }
}

/// Status-message line under a stamp action button. Used by both buy and
/// extend flows for `.purchasing` / `.patching` / `.usable` / `.completed`
/// / `.failed` copy — one place to tune the typography across both.
@MainActor
func stampStatusText(_ text: String, tint: Color) -> some View {
    Text(text)
        .font(.callout)
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, alignment: .leading)
}
