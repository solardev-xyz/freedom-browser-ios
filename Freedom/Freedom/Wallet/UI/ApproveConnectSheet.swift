import SwiftUI

/// `eth_requestAccounts` approval. Address is derived from the unlocked
/// vault for display; the bridge re-derives after `.approved` fires (same
/// single account in v1, so no drift).
@MainActor
struct ApproveConnectSheet: View {
    @Environment(Vault.self) private var vault
    @Environment(\.dismiss) private var dismiss

    let approval: ApprovalRequest

    @State private var address: String?
    @State private var deriveError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ApprovalOriginStrip(origin: approval.origin, caption: "This site wants to connect")
                    switch vault.state {
                    case .empty:
                        Label("Set up a wallet first, then try again.", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                    case .locked:
                        ApprovalUnlockStrip()
                    case .unlocked:
                        unlockedBody
                    }
                }
                .padding(20)
            }
            .navigationTitle("Connect wallet")
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
        .task(id: vault.state) { await deriveAddressIfUnlocked() }
    }

    @ViewBuilder private var unlockedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You'll share this account with the site:")
                .font(.caption).foregroundStyle(.secondary)
            if let address {
                AddressPill(address: address)
            } else if let deriveError {
                Text(deriveError).font(.caption).foregroundStyle(.red)
            } else {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("The site can read your balance and request signatures. You can revoke access later from the wallet's connected-sites list.")
                .font(.caption)
                .foregroundStyle(.secondary)
            PrimaryActionButton(
                title: "Approve",
                systemImage: "checkmark",
                isEnabled: address != nil,
                action: approve
            )
        }
    }

    private func approve() {
        approval.decide(.approved)
        dismiss()
    }

    private func deriveAddressIfUnlocked() async {
        guard vault.state == .unlocked else { return }
        do {
            address = try vault.signingKey(at: .mainUser).ethereumAddress
        } catch {
            deriveError = error.localizedDescription
        }
    }
}
