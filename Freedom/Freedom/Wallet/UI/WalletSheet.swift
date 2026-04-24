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
                case .locked, .unlocked:
                    WalletHomePlaceholder()
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
    }
}
