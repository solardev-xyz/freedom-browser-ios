import SwiftUI

/// Wallet-specific settings page reached from the top-level Settings hub.
/// Hosts the security-level disclosure, recovery-phrase reveal, and the
/// destructive wipe action that used to clutter `WalletHomeView`.
@MainActor
struct WalletSettingsView: View {
    @Environment(Vault.self) private var vault
    @Environment(WalletAccountStore.self) private var accounts

    @State private var revealedPhrase: [String]?
    @State private var revealedKey: RevealedPrivateKey?
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
                Button {
                    Task { await revealKey() }
                } label: {
                    Label("Show private key", systemImage: "key.horizontal.fill")
                }
                if let revealError {
                    Text(revealError).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("Both re-prompt for biometrics. The recovery phrase controls every account and identity; the private key is the active account's (\(accounts.activeAccount.name)) and is what other wallets' \"import private key\" fields take. Anyone with either can drain this wallet.")
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
        .navigationDestination(item: $revealedKey) { key in
            PrivateKeyView(key: key)
        }
    }

    private func revealKey() async {
        revealError = nil
        do {
            let address = Hex.checksummed(try vault.signingKey(at: vault.activeAccountPath).ethereumAddress)
            let key = try await vault.revealPrivateKey()
            revealedKey = RevealedPrivateKey(address: address, hex: PrivateKeyExport.hex(key))
        } catch {
            revealError = error.localizedDescription
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
