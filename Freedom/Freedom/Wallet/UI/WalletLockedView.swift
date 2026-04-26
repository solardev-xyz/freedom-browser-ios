import SwiftUI

@MainActor
struct WalletLockedView: View {
    @Environment(Vault.self) private var vault
    @State private var unlockError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                PrimaryActionButton(
                    title: "Unlock",
                    systemImage: "faceid",
                    action: { Task { await attemptUnlock() } }
                )
                if let unlockError {
                    Text(unlockError).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Wallet locked").font(.headline)
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
