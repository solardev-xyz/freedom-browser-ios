import SwiftUI

/// First screen of the onboarding flow — a two-option chooser between
/// generating a fresh wallet and importing an existing BIP-39 phrase.
@MainActor
struct VaultSetupView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Set up your wallet")
                        .font(.title2).bold()
                    Text("Freedom embeds a keychain-protected Ethereum wallet. It stays on this device and syncs encrypted to your other Apple devices via iCloud Keychain.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 12) {
                    NavigationLink(destination: VaultCreateView()) {
                        SetupOptionCard(
                            icon: "sparkles",
                            title: "Create new wallet",
                            subtitle: "Generate a fresh 24-word recovery phrase. Takes a second."
                        )
                    }
                    NavigationLink(destination: VaultImportView()) {
                        SetupOptionCard(
                            icon: "arrow.down.doc",
                            title: "Import existing wallet",
                            subtitle: "Paste a 12 or 24-word BIP-39 recovery phrase."
                        )
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
    }
}

private struct SetupOptionCard: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
