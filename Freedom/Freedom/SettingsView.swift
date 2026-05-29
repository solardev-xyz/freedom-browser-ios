import SwiftUI

/// Top-level settings hub. iOS Settings-style: tap a row to drill into
/// a per-section page. Done invalidates the resolver cache + pool
/// quarantine so any setting changes (RPC URLs, quorum config, CCIP
/// toggle) take effect on the next navigation.
struct SettingsView: View {
    @Environment(ENSResolver.self) private var resolver
    @Environment(ChainRegistry.self) private var chainRegistry
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
                    SwarmSettingsView()
                } label: {
                    Label("Swarm", systemImage: "circle.hexagongrid.fill")
                }
                NavigationLink {
                    IPFSSettingsView()
                } label: {
                    Label("IPFS", systemImage: "globe.asia.australia")
                }
                NavigationLink {
                    RPCSettingsView()
                } label: {
                    Label("RPC", systemImage: "antenna.radiowaves.left.and.right")
                }
                NavigationLink {
                    AdblockSettingsView()
                } label: {
                    Label("Ad Blocking", systemImage: "shield.lefthalf.filled")
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
        // Drop quarantine + shuffle on every per-chain pool so a URL the
        // user just edited / re-added is reconsidered on the next request.
        chainRegistry.invalidateAllPools()
        dismiss()
    }
}
