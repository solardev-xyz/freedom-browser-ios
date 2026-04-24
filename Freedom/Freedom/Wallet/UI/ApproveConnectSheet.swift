import SwiftUI

/// `eth_requestAccounts` approval. The sheet is driven by
/// `BrowserTab.pendingEthereumApproval`; the bridge parked a continuation
/// and is waiting on the `approval.decide(…)` callback. Swipe-to-dismiss
/// counts as deny (the presenting Binding's setter fires `.denied`
/// before clearing state).
///
/// Vault states the sheet handles: `.empty` blocks approval and nudges
/// the user to set up the wallet; `.locked` shows an unlock step before
/// revealing the account; `.unlocked` shows the account and Approve.
@MainActor
struct ApproveConnectSheet: View {
    @Environment(Vault.self) private var vault
    @Environment(\.dismiss) private var dismiss

    let approval: ApprovalRequest

    @State private var address: String?
    @State private var deriveError: String?
    @State private var unlockError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    originStrip
                    switch vault.state {
                    case .empty:
                        emptyBody
                    case .locked:
                        lockedBody
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

    private var originStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("This site wants to connect").font(.caption).foregroundStyle(.secondary)
            Text(approval.origin.displayString)
                .font(.headline)
                .textSelection(.enabled)
            Text(approval.origin.schemeDisplayLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var emptyBody: some View {
        Label(
            "Set up a wallet first from the wallet tab, then try again.",
            systemImage: "exclamationmark.circle"
        )
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var lockedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Wallet is locked", systemImage: "lock.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            PrimaryActionButton(
                title: "Unlock to continue",
                systemImage: "faceid",
                action: { Task { await attemptUnlock() } }
            )
            if let unlockError {
                Text(unlockError).font(.caption).foregroundStyle(.red)
            }
        }
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
        guard let address else { return }
        approval.decide(.approved(account: address))
        dismiss()
    }

    private func attemptUnlock() async {
        unlockError = nil
        do {
            try await vault.unlock()
        } catch {
            unlockError = error.localizedDescription
        }
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
