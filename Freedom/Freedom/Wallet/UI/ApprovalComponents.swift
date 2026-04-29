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

/// Toggle + caption card for the auto-approve opt-in across approval
/// sheets. Single source of truth for the visual styling so a future
/// tweak lands once.
@MainActor
struct ApprovalAutoApproveCard: View {
    let label: String
    let caption: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(label, isOn: $isOn)
                .font(.callout)
                .tint(.accentColor)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// `caption — value` row for approval-sheet detail cards. Shared between
/// the typed-data, send-tx, and chain-switch sheets.
@MainActor
struct ApprovalLabeledRow: View {
    let label: String
    let value: String
    var valueFont: Font = .caption.monospaced()
    var valueWeight: Font.Weight = .regular

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(valueFont.weight(valueWeight))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
