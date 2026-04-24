import SwiftUI

@MainActor
struct WalletHomePlaceholder: View {
    @Environment(Vault.self) private var vault
    @State private var address: String?
    @State private var unlockError: String?
    @State private var isShowingWipeConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusHeader
                stateBody
                Divider().padding(.vertical, 8)
                // TODO(M5.7): move to Advanced settings once the real wallet
                // home lands in WP5. Exposed here for now so dev + test flows
                // can wipe without reinstalling.
                Button("Wipe wallet", role: .destructive) {
                    isShowingWipeConfirm = true
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }
            .padding(20)
        }
        .task(id: vault.state) {
            address = (vault.state == .unlocked)
                ? try? vault.signingKey(at: .mainUser).ethereumAddress
                : nil
        }
        .confirmationDialog(
            "Wipe this wallet?",
            isPresented: $isShowingWipeConfirm,
            titleVisibility: .visible
        ) {
            Button("Wipe wallet", role: .destructive) {
                Task { try? await vault.wipe() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unless you have your recovery phrase saved elsewhere, funds held by this wallet will be lost permanently. iCloud Keychain propagates the deletion to your other Apple devices.")
        }
    }

    @ViewBuilder private var stateBody: some View {
        switch vault.state {
        case .empty:
            EmptyView()
        case .locked:
            PrimaryActionButton(
                title: "Unlock",
                systemImage: "faceid",
                action: { Task { await attemptUnlock() } }
            )
            if let unlockError {
                Text(unlockError).font(.caption).foregroundStyle(.red)
            }
        case .unlocked:
            if let address {
                AddressPill(address: address)
            }
            Button("Lock wallet") { vault.lock() }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
        }
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: vault.state == .unlocked ? "lock.open.fill" : "lock.fill")
                    .font(.title2)
                    .foregroundStyle(vault.state == .unlocked ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vault.state == .unlocked ? "Wallet unlocked" : "Wallet locked")
                        .font(.headline)
                    Text("Home view with balances arrives in the next milestone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let level = vault.securityLevel {
                SecurityLevelBadge(level: level)
            }
        }
    }

    private func attemptUnlock() async {
        unlockError = nil
        do {
            try await vault.unlock()
        } catch {
            unlockError = error.localizedDescription
        }
    }
}

