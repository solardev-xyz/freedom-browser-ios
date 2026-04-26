import SwiftUI

/// Wallet-specific settings page reached from the top-level Settings hub.
/// Hosts the security-level disclosure, recovery-phrase reveal, and the
/// destructive wipe action that used to clutter `WalletHomeView`.
@MainActor
struct WalletSettingsView: View {
    @Environment(Vault.self) private var vault

    @State private var revealedPhrase: [String]?
    @State private var revealError: String?

    var body: some View {
        Form {
            if let level = vault.securityLevel {
                Section {
                    SecurityLevelBadge(level: level)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                }
            }

            Section {
                Button {
                    Task { await revealPhrase() }
                } label: {
                    Label("Show recovery phrase", systemImage: "key.fill")
                }
                if let revealError {
                    Text(revealError).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("Re-prompts for biometrics. Treat the words like a password — anyone with them can drain this wallet.")
            }

            Section {
                WipeWalletButton()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }
        }
        .navigationTitle("Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $revealedPhrase) { words in
            RecoveryPhraseView(words: words)
        }
    }

    private func revealPhrase() async {
        revealError = nil
        do {
            let mnemonic = try await vault.revealMnemonic()
            revealedPhrase = mnemonic.words
        } catch {
            revealError = error.localizedDescription
        }
    }
}
