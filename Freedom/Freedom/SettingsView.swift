import SwiftUI

/// Top-level settings hub. iOS Settings-style: tap a row to drill into
/// a per-section page. Done invalidates the resolver cache + pool
/// quarantine so any setting changes (RPC URLs, quorum config, CCIP
/// toggle) take effect on the next navigation.
struct SettingsView: View {
    @Environment(ENSResolver.self) private var resolver
    @Environment(ChainRegistry.self) private var chainRegistry
    @Environment(ChainStore.self) private var chainStore
    @Environment(\.dismiss) private var dismiss

    /// Single typed path that backs every settings sub-page push.
    /// Going entirely value-based avoids the SwiftUI mixed-model
    /// bounce where a value-push from inside a destination-pushed
    /// view forces the visible stack to re-sync.
    @State private var path: [SettingsPath] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                NavigationLink(value: SettingsPath.wallet) {
                    Label("Wallet", systemImage: "wallet.bifold.fill")
                }
                NavigationLink(value: SettingsPath.ens) {
                    Label("ENS", systemImage: "globe")
                }
                NavigationLink(value: SettingsPath.swarm) {
                    Label("Swarm", systemImage: "circle.hexagongrid.fill")
                }
                NavigationLink(value: SettingsPath.ipfs) {
                    Label("IPFS", systemImage: "globe.asia.australia")
                }
                NavigationLink(value: SettingsPath.rpc) {
                    Label("RPC", systemImage: "antenna.radiowaves.left.and.right")
                }
                NavigationLink(value: SettingsPath.adblock) {
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
            .navigationDestination(for: SettingsPath.self) { route in
                destination(for: route)
            }
        }
        .environment(\.settingsPath, $path)
    }

    @ViewBuilder
    private func destination(for route: SettingsPath) -> some View {
        switch route {
        case .wallet:
            WalletSettingsView()
        case .ens:
            ENSSettingsView()
        case .swarm:
            SwarmSettingsView()
        case .ipfs:
            IPFSSettingsView()
        case .rpc:
            RPCSettingsView()
        case .adblock:
            AdblockSettingsView()
        case .chainEditor(let id):
            if let chain = chainStore.chain(id: id) {
                ChainRPCDetailView(chain: chain)
            }
        case .chainlistSearch:
            ChainlistSearchView()
        case .addChainForm(let prefill):
            AddChainForm(prefill: prefill)
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
