import BigInt
import SwiftUI
import web3

/// Pushed onto SendFlowView's nav stack when the user taps the "From"
/// row. Lists every (chain, asset) the user holds with non-zero balance,
/// grouped by chain. Tap a row → write back to the parent's bindings,
/// pop. Two-chain serial fetch (no parallel withTaskGroup hop dance —
/// each chain's `TokenBalanceFetcher.fetch` already parallelizes within).
@MainActor
struct AssetPickerView: View {
    @Environment(Vault.self) private var vault
    @Environment(ChainRegistry.self) private var chains
    @Environment(ChainStore.self) private var chainStore
    @Environment(WalletBalanceStore.self) private var balances
    @Environment(\.dismiss) private var dismiss

    @Binding var selectedChain: Chain
    @Binding var selectedAsset: Token

    @State private var entries: [Entry] = []
    @State private var isLoading = true

    private struct Entry: Identifiable {
        let chain: Chain
        let token: Token
        let balance: BigUInt
        var id: String { "\(chain.id):\(token.id)" }
    }

    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading balances…").foregroundStyle(.secondary)
                    }
                }
            } else if entries.isEmpty {
                Section {
                    Text("No assets to send.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(chainStore.allChains()) { chain in
                    let chainEntries = entries.filter { $0.chain.id == chain.id }
                    if !chainEntries.isEmpty {
                        Section(chain.displayName) {
                            ForEach(chainEntries) { entry in
                                pickerRow(entry)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("From")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func pickerRow(_ entry: Entry) -> some View {
        Button {
            selectedChain = entry.chain
            selectedAsset = entry.token
            dismiss()
        } label: {
            HStack {
                AssetRow(token: entry.token, balance: entry.balance)
                if entry.chain.id == selectedChain.id, entry.token.id == selectedAsset.id {
                    Image(systemName: "checkmark")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Cached balances render immediately; each chain is then refreshed
    /// silently (the store skips chains fetched moments ago).
    private func load() async {
        guard let derived = try? vault.signingKey(at: vault.activeWalletPath).ethereumAddress else {
            isLoading = false
            return
        }
        let chains = chainStore.allChains()
        if balances.holder == derived {
            let cached = collect(chains) { balances.balances(on: $0) }
            if !cached.isEmpty {
                entries = cached
                isLoading = false
            }
        }
        var fresh: [Chain: [Token: BigUInt]] = [:]
        for chain in chains {
            fresh[chain] = await balances.refresh(holder: derived, chain: chain)
        }
        entries = collect(chains) { fresh[$0] ?? balances.balances(on: $0) }
        isLoading = false
    }

    private func collect(_ chains: [Chain], _ balances: (Chain) -> [Token: BigUInt]?) -> [Entry] {
        var collected: [Entry] = []
        for chain in chains {
            guard let known = balances(chain) else { continue }
            for token in TokenRegistry.tokens(for: chain) {
                if let balance = known[token], balance > 0 {
                    collected.append(Entry(chain: chain, token: token, balance: balance))
                }
            }
        }
        return collected
    }
}
