import SwiftUI

/// `radicle_seed` approval — a per-repo prompt because seeding commits
/// the user's disk + bandwidth indefinitely (it also serves the repo to
/// other peers). The auto-approve toggle persists per origin.
@MainActor
struct RadicleSeedSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RadiclePermissionStore.self) private var permissionStore

    let approval: ApprovalRequest
    let rid: String

    @State private var autoApprove = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ApprovalOriginStrip(
                        origin: approval.origin,
                        caption: "This site wants your node to seed a repository"
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Repository")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(rid)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    Text(
                        "Seeding downloads the repository to this device, "
                        + "keeps it updated, and serves it to other peers — "
                        + "using storage and bandwidth until you unseed it."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Toggle(isOn: $autoApprove) {
                        Text("Always allow this site to seed")
                            .font(.subheadline)
                    }
                    PrimaryActionButton(
                        title: "Seed repository",
                        systemImage: "checkmark",
                        action: approve
                    )
                }
                .padding(20)
            }
            .navigationTitle("Seed on Radicle")
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

    private func approve() {
        if autoApprove {
            permissionStore.setAutoApproveSeed(origin: approval.origin.key, enabled: true)
        }
        approval.decide(.approved)
        dismiss()
    }
}
