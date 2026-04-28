import SwiftUI

/// `swarm_publishData` / `swarm_publishFiles` approval. Shows the size
/// + content type + optional name for the user to confirm; the toggle
/// at the bottom upgrades the per-call approval into a per-origin
/// auto-approve grant on `SwarmPermissionStore`.
@MainActor
struct SwarmPublishSheet: View {
    @Environment(SwarmPermissionStore.self) private var permissionStore
    @Environment(\.dismiss) private var dismiss

    let approval: ApprovalRequest
    let details: SwarmPublishDetails

    @State private var grantAutoApprove: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ApprovalOriginStrip(
                        origin: approval.origin,
                        caption: "This site wants to publish to Swarm"
                    )
                    detailsCard
                    autoApproveToggle
                    PrimaryActionButton(
                        title: "Publish",
                        systemImage: "arrow.up.circle",
                        action: approve
                    )
                }
                .padding(20)
            }
            .navigationTitle("Confirm publish")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        approval.decide(.denied)
                        dismiss()
                    }
                }
            }
        }
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch details.mode {
            case .data(let contentType, let name):
                ApprovalLabeledRow(label: "Size", value: Self.formatBytes(details.sizeBytes))
                ApprovalLabeledRow(label: "Content type", value: contentType)
                if let name {
                    ApprovalLabeledRow(label: "Name", value: name)
                }
            case .files(let paths, let indexDocument):
                ApprovalLabeledRow(
                    label: "Files",
                    value: "\(paths.count) file\(paths.count == 1 ? "" : "s")"
                )
                ApprovalLabeledRow(label: "Size", value: Self.formatBytes(details.sizeBytes))
                if let indexDocument {
                    ApprovalLabeledRow(label: "Index", value: indexDocument)
                }
                // Long single paths get middle-truncated rather than
                // overflowing the row width.
                ApprovalLabeledRow(label: "Paths", value: Self.previewPaths(paths))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// First three paths joined by ", ", plus a "…and N more" suffix
    /// when the dapp uploads more than three. Matches desktop's
    /// publish-sheet preview line.
    private static func previewPaths(_ paths: [String]) -> String {
        let head = paths.prefix(3).joined(separator: ", ")
        let extra = paths.count > 3 ? " …and \(paths.count - 3) more" : ""
        return head + extra
    }

    private var autoApproveToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                "Auto-approve future publishes from this site",
                isOn: $grantAutoApprove
            )
            .font(.callout)
            .tint(.accentColor)
            Text(
                "Skips this sheet for subsequent uploads from "
                + approval.origin.displayString
                + ". You can revoke this from the connected-sites list later."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func approve() {
        if grantAutoApprove {
            permissionStore.setAutoApprovePublish(
                origin: approval.origin.key, enabled: true
            )
        }
        approval.decide(.approved)
        dismiss()
    }

    /// 1000-base to match `StampsView` and bee/bee-js convention.
    /// `ByteCountFormatter` defaults to 1024-base (`.file`), which would
    /// show "1.0 MB" at 1.05e6 bytes — different from how the stamp
    /// surface displays the same number.
    private static func formatBytes(_ bytes: Int) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        let kb = Double(bytes) / 1_000
        if kb >= 1 { return String(format: "%.0f KB", kb) }
        return "\(bytes) B"
    }
}
