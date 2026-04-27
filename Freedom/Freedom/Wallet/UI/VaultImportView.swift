import SwiftUI
import SwarmKit

/// Import an existing BIP-39 phrase. Accepts any standard word count
/// (12 / 15 / 18 / 21 / 24) — we don't refuse shorter phrases from
/// wallets the user wants to move across, even though we only generate 24.
///
/// On success, the Bee node's identity is swapped to one derived from the
/// imported mnemonic. Same-mnemonic re-import (a user recovering from a
/// wipe with the seed they just had) is detected by `BeeIdentityInjector`
/// and short-circuits — no node restart, no state wipe.
@MainActor
struct VaultImportView: View {
    @Environment(Vault.self) private var vault
    @Environment(SwarmNode.self) private var swarm
    @State private var phrase: String = ""
    @State private var stage: SetupStage = .idle
    @FocusState private var phraseFocused: Bool

    private var validationResult: Result<Mnemonic, Mnemonic.Error>? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            return .success(try Mnemonic(phrase: trimmed))
        } catch let error as Mnemonic.Error {
            return .failure(error)
        } catch {
            // `Mnemonic(phrase:)` only throws `Mnemonic.Error`; anything
            // else here would be a contract violation in that initializer.
            preconditionFailure("Mnemonic threw unexpected error type: \(error)")
        }
    }

    private var canImport: Bool {
        if case .success = validationResult { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch stage {
                case .idle, .working:
                    editor
                    validationHint
                    PrimaryActionButton(
                        title: "Import wallet",
                        busyTitle: "Importing…",
                        isWorking: stage == .working,
                        isEnabled: canImport,
                        action: { Task { await importVault() } }
                    )
                case .done(let address):
                    VaultResultView(title: "Wallet imported", address: address, footnote: nil)
                case .failed(let message):
                    VaultFailureView(
                        title: "Couldn't import wallet",
                        message: message,
                        onRetry: { stage = .idle }
                    )
                }
            }
            .padding(20)
        }
        .navigationTitle("Import wallet")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recovery phrase")
                .font(.subheadline).bold()
            Text("Paste the 12-24 words separated by spaces. We store them encrypted on this device only — the app never sends them anywhere.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $phrase)
                .focused($phraseFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack {
                PasteButton(payloadType: String.self) { strings in
                    if let first = strings.first {
                        Task { @MainActor in phrase = first }
                    }
                }
                .labelStyle(.titleAndIcon)
                Spacer()
                if !phrase.isEmpty {
                    Button("Clear", role: .destructive) { phrase = "" }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder private var validationHint: some View {
        switch validationResult {
        case .failure(let error):
            Label(describe(error), systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
        case .success:
            Label("Phrase looks good.", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        case nil:
            EmptyView()
        }
    }

    private func importVault() async {
        guard case .success(let mnemonic) = validationResult else { return }
        stage = .working
        phraseFocused = false
        do {
            try await vault.create(mnemonic: mnemonic)
            let address = try vault.signingKey(at: .mainUser).ethereumAddress
            try await BeeIdentityInjector.inject(vault: vault, swarm: swarm)
            phrase = ""
            stage = .done(address: address)
        } catch {
            stage = .failed(message: error.localizedDescription)
        }
    }

    private func describe(_ error: Mnemonic.Error) -> String {
        switch error {
        case .invalidWordCount: return "Phrase should be 12, 15, 18, 21, or 24 words."
        case .unknownWord(let w): return "\"\(w)\" isn't a BIP-39 word."
        case .invalidChecksum: return "Checksum doesn't match — check the word order."
        case .invalidEntropyLength: return "Phrase should be 12, 15, 18, 21, or 24 words."
        }
    }
}
