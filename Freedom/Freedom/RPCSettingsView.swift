import SwiftUI

/// Chain list — the top-level Settings → RPC page. Each row is a chain
/// from `ChainStore`, drilling into `ChainRPCDetailView` for the per-
/// chain provider editor. Mainnet + Gnosis are seeded built-ins and
/// can't be deleted (they're protocol-pinned: ENS / Colibri only run
/// against mainnet, and the embedded bee node depends on Gnosis at
/// the chain-store level). User-added chains (Phase 3+: chainlist.org
/// + manual form) get swipe-to-delete.
struct RPCSettingsView: View {
    @Environment(ChainStore.self) private var chainStore

    var body: some View {
        Form {
            Section {
                ForEach(chainStore.allChains()) { chain in
                    NavigationLink {
                        ChainRPCDetailView(chain: chain)
                    } label: {
                        chainRow(chain)
                    }
                }
                .onDelete(perform: deleteChains)
            } footer: {
                Text("Tap a chain to edit its RPC providers. Mainnet and Gnosis are required.")
            }
        }
        .navigationTitle("RPC")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func chainRow(_ chain: Chain) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(chain.displayName)
                Text(providerCountLabel(for: chain))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func providerCountLabel(for chain: Chain) -> String {
        let count = chainStore.rpcURLs(forChainID: chain.id).count
        return count == 1 ? "1 provider" : "\(count) providers"
    }

    /// `.onDelete` fires for any swipe; we drop the indices that point at
    /// built-in rows so the delete is a no-op for mainnet / Gnosis. iOS
    /// also won't render the delete affordance on those rows once Phase 3
    /// custom chains land alongside them, but the guard here is the
    /// canonical safety net.
    private func deleteChains(at offsets: IndexSet) {
        let chains = chainStore.allChains()
        for index in offsets {
            guard chains.indices.contains(index) else { continue }
            let chain = chains[index]
            guard !chain.isBuiltIn else { continue }
            chainStore.deleteChain(id: chain.id)
        }
    }
}
