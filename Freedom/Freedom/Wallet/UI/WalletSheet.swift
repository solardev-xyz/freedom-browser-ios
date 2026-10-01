import SwiftUI

@MainActor
struct WalletSheet: View {
    @Environment(Vault.self) private var vault
    @Binding var isPresented: Bool
    /// A Send form to push the moment the vault is unlocked — an
    /// `ethereum:` payment link. Setup or unlock still come first; the
    /// request waits, then lands on top of the wallet home.
    var initialSend: SendRequest? = nil
    @State private var path = NavigationPath()
    @State private var pushedInitialSend = false

    var body: some View {
        NavigationStack(path: $path) {
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
            .navigationDestination(for: SendRequest.self) { request in
                SendFlowView(chain: request.chain, recipient: request.recipient, amount: request.amount)
            }
            .onAppear(perform: pushInitialSendIfUnlocked)
            .onChange(of: vault.state) { _, _ in pushInitialSendIfUnlocked() }
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

    private func pushInitialSendIfUnlocked() {
        guard let initialSend, !pushedInitialSend, vault.state == .unlocked else { return }
        pushedInitialSend = true
        path.append(initialSend)
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
