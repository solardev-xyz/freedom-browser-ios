import SwiftUI

@MainActor
struct WalletSheet: View {
    @Environment(Vault.self) private var vault
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            Group {
                switch vault.state {
                case .empty:
                    VaultSetupView()
                case .locked:
                    WalletLockedView()
                case .unlocked:
                    WalletHomeView()
                }
            }
            .navigationTitle("Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                }
            }
        }
        // Exposes a "close the whole sheet" action to deeply-pushed views
        // (send flow's Done button on the confirmation screen). Apple's
        // `.dismiss` only pops one nav level; this is a full-sheet close.
        .environment(\.closeWalletSheet, CloseWalletSheetAction { isPresented = false })
    }
}

struct CloseWalletSheetAction {
    let action: () -> Void
    @MainActor func callAsFunction() { action() }
}

private struct CloseWalletSheetKey: EnvironmentKey {
    static let defaultValue = CloseWalletSheetAction(action: {
        // Default fires when someone reaches for `@Environment(\.closeWalletSheet)`
        // outside WalletSheet's subtree (e.g. an Xcode preview). Loud in
        // debug; silent in release so real users don't crash on a missing
        // provider.
        assert(false, "closeWalletSheet called without a provider in scope")
    })
}

extension EnvironmentValues {
    var closeWalletSheet: CloseWalletSheetAction {
        get { self[CloseWalletSheetKey.self] }
        set { self[CloseWalletSheetKey.self] = newValue }
    }
}
