import SwiftUI

/// `wallet_switchEthereumChain` approval. Bridge has already resolved the
/// requested chainID against `ChainRegistry` (unknown chains rejected
/// with `4902` before the sheet shows) and short-circuited the no-op
/// case (already on the requested chain → silent `null`); this sheet
/// only handles real switches.
@MainActor
struct ApproveChainSwitchSheet: View {
    @Environment(\.dismiss) private var dismiss

    let approval: ApprovalRequest
    let details: SwitchChainDetails

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ApprovalOriginStrip(origin: approval.origin, caption: "This site wants to switch chains")
                    chainCard
                    Text("Switching chains affects every connected dapp — they'll see a chainChanged event.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    PrimaryActionButton(
                        title: "Switch",
                        systemImage: "arrow.triangle.2.circlepath",
                        action: approve
                    )
                }
                .padding(20)
            }
            .navigationTitle("Switch chain")
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

    private var chainCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ApprovalLabeledRow(label: "From", value: details.from.displayName, valueFont: .callout)
            ApprovalLabeledRow(label: "To", value: details.to.displayName, valueFont: .callout, valueWeight: .semibold)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func approve() {
        approval.decide(.approved)
        dismiss()
    }
}
