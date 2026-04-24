import SwiftUI
import UIKit

/// Displays the 24-word mnemonic in a numbered grid. Reached only via
/// `Vault.revealMnemonic()` which forces a fresh biometric prompt — we
/// don't cache the words on Vault, so landing here means the user just
/// re-authenticated explicitly for this view.
@MainActor
struct RecoveryPhraseView: View {
    let words: [String]
    @State private var isRevealed: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                warning
                if isRevealed {
                    wordGrid
                    HStack(spacing: 12) {
                        Button {
                            copyPhrase()
                        } label: {
                            Label("Copy all", systemImage: "doc.on.doc")
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
        .navigationTitle("Recovery phrase")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, new in
            // Hide on background/inactive so snapshots / app switcher
            // previews don't leak the words. Also guards against a user
            // walking away mid-reveal.
            if new != .active { isRevealed = false }
        }
    }

    private func copyPhrase() {
        // 60s expiry + .localOnly = no iCloud Universal Clipboard, gone
        // from the pasteboard after a minute even if the user forgets
        // to clear it. `public.utf8-plain-text` is the UTI for Text.
        UIPasteboard.general.setItems(
            [["public.utf8-plain-text": words.joined(separator: " ")]],
            options: [
                .expirationDate: Date().addingTimeInterval(60),
                .localOnly: true,
            ]
        )
    }

    private var warning: some View {
        Label {
            Text("Anyone with these 24 words can access your wallet. Don't share them. Don't photograph them. Write them down offline.")
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

    private var wordGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: 8
        ) {
            ForEach(Array(words.enumerated()), id: \.offset) { idx, word in
                HStack(spacing: 6) {
                    Text("\(idx + 1).")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .trailing)
                    Text(word)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
