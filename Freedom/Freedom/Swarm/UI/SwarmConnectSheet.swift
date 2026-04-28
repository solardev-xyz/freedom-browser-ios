import SwiftUI

/// `swarm_requestAccess` approval. No account derivation (swarm grants
/// are per-origin, not per-account) and no chain — this sheet is
/// strictly about handing the dapp permission to publish through the
/// user's bee node.
@MainActor
struct SwarmConnectSheet: View {
    @Environment(\.dismiss) private var dismiss

    let approval: ApprovalRequest

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ApprovalOriginStrip(
                        origin: approval.origin,
                        caption: "This site wants to publish to your Swarm node"
                    )
                    Text(
                        "Granting access lets the site upload data and "
                        + "manage feeds through your Swarm node. Each "
                        + "publish or feed write still asks for your "
                        + "approval. You can revoke access anytime."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    PrimaryActionButton(
                        title: "Approve",
                        systemImage: "checkmark",
                        action: approve
                    )
                }
                .padding(20)
            }
            .navigationTitle("Connect to Swarm")
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
        approval.decide(.approved)
        dismiss()
    }
}
