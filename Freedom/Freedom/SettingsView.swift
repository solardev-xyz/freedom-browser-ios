import SwiftUI

/// Top-level settings hub. iOS Settings-style: tap a row to drill into
/// a per-section page. Done invalidates the resolver cache + pool
/// quarantine so any setting changes (RPC URLs, quorum config, CCIP
/// toggle) take effect on the next navigation.
struct SettingsView: View {
    @Environment(ENSResolver.self) private var resolver
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    WalletSettingsView()
                } label: {
                    Label("Wallet", systemImage: "wallet.bifold.fill")
                }
                NavigationLink {
                    ENSSettingsView()
                } label: {
                    Label("ENS", systemImage: "globe")
                }
                NavigationLink {
                    RPCSettingsView()
                } label: {
                    Label("RPC", systemImage: "antenna.radiowaves.left.and.right")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { finish() }
                }
            }
        }
    }

    private func finish() {
        resolver.invalidate()
        dismiss()
    }
}
