import SwiftUI
import SwarmKit

/// Shared lifecycle for the create and import flows. `.idle` covers both
/// "waiting for input" in import and "waiting for the Create button" in create.
enum SetupStage: Equatable {
    case idle
    case working
    case done(address: String)
    case failed(message: String)
}

/// Button style for the wallet's primary filled action. Used by
/// `PrimaryActionButton`, `NavigationLink`-driven send button, and any
/// future "go ahead and do the thing" affordance. Exists so the styling
/// doesn't drift between Button and NavigationLink call sites.
struct PrimaryActionStyle: ButtonStyle {
    var isEnabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(isEnabled ? Color.accentColor : Color.accentColor.opacity(0.3))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .fontWeight(.semibold)
    }
}

/// Monospaced address with the chrome used everywhere the wallet shows a
/// hex address — success screens, the placeholder home, future wallet home.
struct AddressPill: View {
    let address: String

    var body: some View {
        Text(address)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct VaultResultView: View {
    let title: String
    let address: String
    let footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title)
                    .foregroundStyle(.green)
                Text(title).font(.title2).bold()
            }
            Text("Your wallet address:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            AddressPill(address: address)
            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct VaultFailureView: View {
    let title: String
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text(title).font(.title2).bold()
            }
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Try again", action: onRetry)
                .buttonStyle(.bordered)
        }
    }
}

/// Full-width accent-filled button with a busy state. Used for Create,
/// Import, Unlock — every primary-action surface in the wallet.
struct PrimaryActionButton: View {
    let title: String
    var busyTitle: String? = nil
    var systemImage: String? = nil
    var isWorking: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                if isWorking {
                    ProgressView().tint(.white)
                }
                if let systemImage, !isWorking {
                    Image(systemName: systemImage)
                }
                Text(isWorking ? (busyTitle ?? title) : title)
            }
        }
        .buttonStyle(PrimaryActionStyle(isEnabled: isEnabled))
        .disabled(!isEnabled || isWorking)
    }
}

struct WipeWalletButton: View {
    @Environment(Vault.self) private var vault
    @Environment(SwarmNode.self) private var swarm
    @Environment(BeeIdentityCoordinator.self) private var beeIdentity
    @State private var isShowingConfirm = false

    var body: some View {
        Button("Wipe wallet", role: .destructive) {
            isShowingConfirm = true
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
        .confirmationDialog(
            "Wipe this wallet?",
            isPresented: $isShowingConfirm,
            titleVisibility: .visible
        ) {
            Button("Wipe wallet", role: .destructive) {
                Task {
                    try? await vault.wipe()
                    // Without the revert, the node keeps signing as a key
                    // derived from the mnemonic the user just chose to forget.
                    beeIdentity.revertInBackground(swarm: swarm)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unless you have your recovery phrase saved elsewhere, funds held by this wallet will be lost permanently. iCloud Keychain propagates the deletion to your other Apple devices.")
        }
    }
}

struct SecurityLevelBadge: View {
    let level: VaultSecurityLevel

    var body: some View {
        Label {
            Text(style.copy).font(.caption).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: style.icon).font(.caption)
        }
        .foregroundStyle(style.tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(style.tint.opacity(0.12))
        .clipShape(Capsule())
    }

    private var style: (icon: String, tint: Color, copy: String) {
        switch level {
        case .cloudSynced:
            return ("icloud.fill", .blue,
                    "iCloud Keychain backup — restores on your other Apple devices.")
        case .protected:
            return ("shield.lefthalf.filled", .purple,
                    "Secure Enclave protected — this device only.")
        case .deviceBound:
            return ("iphone", .orange,
                    "This device only — no iCloud backup. Set a device passcode to enable backup.")
        }
    }
}
