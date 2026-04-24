import SwiftUI

@MainActor
struct ApprovalOriginStrip: View {
    let origin: OriginIdentity
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption).font(.caption).foregroundStyle(.secondary)
            Text(origin.displayString)
                .font(.headline)
                .textSelection(.enabled)
            Text(origin.schemeDisplayLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor
struct ApprovalUnlockStrip: View {
    @Environment(Vault.self) private var vault
    @State private var unlockError: String?

    var body: some View {
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

    private func attemptUnlock() async {
        unlockError = nil
        do {
            try await vault.unlock()
        } catch {
            unlockError = error.localizedDescription
        }
    }
}
