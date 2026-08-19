import SwiftUI

/// Radicle signing-tier grant — identity disclosure plus COB writes
/// (issues, comments, state changes) as the user's one Radicle
/// identity. One deliberate grant covers the tier, like an OAuth scope;
/// the copy must make clear the site can then author content as the
/// user on the network, irrevocably once gossiped.
@MainActor
struct RadicleSigningSheet: View {
    @Environment(\.dismiss) private var dismiss

    let approval: ApprovalRequest

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ApprovalOriginStrip(
                        origin: approval.origin,
                        caption: "This site wants to write as your Radicle identity"
                    )
                    Text(
                        "Granting this lets the site see your Radicle "
                        + "identity (DID) and publish issues and comments "
                        + "signed by you. Published writes spread to other "
                        + "nodes and cannot be taken back. This covers all "
                        + "future writes by this site until you revoke "
                        + "access."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    PrimaryActionButton(
                        title: "Allow writes as me",
                        systemImage: "signature",
                        action: approve
                    )
                }
                .padding(20)
            }
            .navigationTitle("Radicle Identity")
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
