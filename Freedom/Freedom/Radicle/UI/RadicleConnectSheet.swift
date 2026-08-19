import SwiftUI

/// `radicle_requestAccess` approval — the connection-tier grant. Node
/// actions (seeding) and identity/writes each re-prompt on their own
/// tier, so this sheet is strictly about letting the site talk to the
/// user's Radicle node at all.
@MainActor
struct RadicleConnectSheet: View {
    @Environment(\.dismiss) private var dismiss

    let approval: ApprovalRequest

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ApprovalOriginStrip(
                        origin: approval.origin,
                        caption: "This site wants to use your Radicle node"
                    )
                    Text(
                        "Granting access lets the site see your node's "
                        + "status and ask to seed repositories through it. "
                        + "Seeding and writing as your Radicle identity "
                        + "each ask separately. You can revoke access "
                        + "anytime."
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
            .navigationTitle("Connect to Radicle")
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
