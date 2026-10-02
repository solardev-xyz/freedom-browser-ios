import SwiftUI
import UIKit

/// What "Show private key" hands to the view: the account and its key
/// as a `0x` hex string. Hashable so it can drive a navigation
/// destination; never persisted.
struct RevealedPrivateKey: Hashable {
    let address: String
    let hex: String
}

enum PrivateKeyExport {
    /// `0x` + 64 lowercase hex chars, the form every wallet's "import
    /// private key" field accepts.
    static func hex(_ key: Data) -> String {
        "0x" + key.map { String(format: "%02x", $0) }.joined()
    }
}

/// Displays one account's private key. Reached only via
/// `Vault.revealPrivateKey(at:)`, which forces a fresh biometric prompt
/// (desktop "Export Private Key" unlocks first too) — landing here means
/// the user just re-authenticated for this view. Same posture as
/// `RecoveryPhraseView`: hidden until tapped, hidden again when the app
/// leaves the foreground, pasteboard copy expires after a minute.
@MainActor
struct PrivateKeyView: View {
    let key: RevealedPrivateKey
    @State private var isRevealed = false
    @State private var copied = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                warning
                account
                if isRevealed {
                    keyCard
                    HStack(spacing: 12) {
                        Button {
                            copyKey()
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        Button("Hide") { isRevealed = false }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    hiddenCard
                }
            }
            .padding(20)
        }
        .navigationTitle("Private key")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, new in
            if new != .active { isRevealed = false }
        }
    }

    private func copyKey() {
        UIPasteboard.general.setItems(
            [["public.utf8-plain-text": key.hex]],
            options: [
                .expirationDate: Date().addingTimeInterval(60),
                .localOnly: true,
            ]
        )
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private var warning: some View {
        Label {
            Text("Never share your private key. Anyone with it can steal your funds. It controls this one account; the recovery phrase controls every account and identity.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Account").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
            Text(key.address)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private var hiddenCard: some View {
        Button {
            isRevealed = true
        } label: {
            VStack(spacing: 12) {
                Image(systemName: "eye.slash.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Tap to reveal")
                    .font(.subheadline)
                Text("Make sure no one is looking over your shoulder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var keyCard: some View {
        Text(key.hex)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("Private key")
    }
}
