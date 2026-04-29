import SwiftUI

/// Display helpers shared across `SwarmPublishHistoryView` and
/// `SwarmPublishHistoryDetailView`. Same shape as `StampFormatting` —
/// a single home for the byte/time/icon mappings keeps the list and
/// detail surfaces in lockstep when copy is tweaked.
enum SwarmPublishHistoryFormatting {
    static func kindIcon(_ kind: SwarmPublishKind) -> Image {
        switch kind {
        case .data: Image(systemName: "doc.text")
        case .files: Image(systemName: "folder")
        case .feedCreate: Image(systemName: "plus.bubble")
        case .feedUpdate: Image(systemName: "arrow.triangle.2.circlepath")
        case .feedEntry: Image(systemName: "list.bullet")
        }
    }

    /// Title fallback when the dapp didn't supply a name. Worded so it
    /// reads naturally in place of a filename: "Data", not "PublishData".
    static func kindLabel(_ kind: SwarmPublishKind) -> String {
        switch kind {
        case .data: "Data"
        case .files: "Files"
        case .feedCreate: "Feed created"
        case .feedUpdate: "Feed update"
        case .feedEntry: "Feed entry"
        }
    }

    /// `feedEntry` writes a SOC chunk; the reference points at *that*
    /// entry's address, not a feed root manifest. Calling it "Reference"
    /// uniformly would mislead users opening the bzz URL expecting a
    /// browsable manifest.
    static func referenceLabel(_ kind: SwarmPublishKind) -> String {
        switch kind {
        case .feedEntry: "SOC address"
        default: "Reference"
        }
    }

    /// Shortest-form relative date — "5 min ago", "Yesterday", "Mar 14".
    /// Formatter is allocated once; `RelativeDateTimeFormatter` is
    /// thread-safe-for-read after configuration, so a static instance
    /// amortizes across every row × every list re-render.
    static func relativeTime(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: .now)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

/// Mirrors `StampStatusBadge`'s visual language so the two surfaces
/// feel like siblings — orange for in-flight, green for
/// settled-success, red for settled-failure.
@MainActor
struct SwarmPublishHistoryStatusBadge: View {
    let status: SwarmPublishHistoryStatus

    var body: some View {
        Text(label)
            .font(.caption2).fontWeight(.semibold)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15))
            .clipShape(Capsule())
    }

    private var label: String {
        switch status {
        case .uploading: "Uploading"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    private var tint: Color {
        switch status {
        case .uploading: .orange
        case .completed: .green
        case .failed: .red
        }
    }
}
