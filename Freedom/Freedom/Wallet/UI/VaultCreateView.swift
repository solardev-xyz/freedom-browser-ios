import SwiftUI
import SwarmKit

/// Frictionless "quick option" create flow — one tap generates a 24-word
/// mnemonic, encrypts it via `VaultCrypto`, and lands on a success screen.
/// The recovery phrase is never shown here; it's available later via
/// Settings → "Show recovery phrase" behind a biometric gate.
///
/// The Bee node identity swap (~10-15s) is fire-and-forget through
/// `BeeIdentityCoordinator`. UX-wise wallet creation is decoupled from
/// node restart — the user lands on the success screen as soon as the
/// vault is encrypted, and the node finishes catching up in the background.
@MainActor
struct VaultCreateView: View {
    @Environment(Vault.self) private var vault
    @Environment(SwarmNode.self) private var swarm
    @Environment(BeeIdentityCoordinator.self) private var beeIdentity
    @State private var stage: SetupStage = .idle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch stage {
                case .idle, .working:
                    introCopy
                    PrimaryActionButton(
                        title: "Create wallet",
                        busyTitle: "Creating…",
                        isWorking: stage == .working,
                        action: { Task { await createVault() } }
                    )
                case .done(let address):
                    VaultResultView(
                        title: "Wallet ready",
                        address: address,
                        footnote: "You can view your recovery phrase anytime in Settings. Tap Done to close."
                    )
                case .failed(let message):
                    VaultFailureView(
                        title: "Couldn't create wallet",
                        message: message,
                        onRetry: { stage = .idle }
                    )
                }
            }
            .padding(20)
        }
        .navigationTitle("Create wallet")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var introCopy: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ready when you are")
                .font(.title3).bold()
            Text("We'll generate a 24-word recovery phrase, encrypt it on this device, and sync it through iCloud Keychain so it's there on your other Apple devices too.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // iCloud Keychain + `.userPresence` ACL both need a device
            // passcode. Users without one fall back to `.deviceBound`
            // (no cloud backup) — surface the trade once so it's not a
            // surprise later.
            Label {
                Text("Enable a device passcode for iCloud backup. Otherwise your wallet stays on this device only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func createVault() async {
        stage = .working
        let mnemonic = Mnemonic()
        do {
            try await vault.create(mnemonic: mnemonic)
            let address = try vault.signingKey(at: .mainUser).ethereumAddress
            beeIdentity.injectInBackground(vault: vault, swarm: swarm)
            stage = .done(address: address)
        } catch {
            stage = .failed(message: error.localizedDescription)
        }
    }
}
