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
                ForEach(Chain.all) { chain in
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

    private func load() async {
        guard let derived = try? vault.signingKey(at: .mainUser).ethereumAddress else {
            isLoading = false
            return
        }
        let holder = EthereumAddress(derived)
        let fetcher = TokenBalanceFetcher(walletRPC: chains.walletRPC)

        var collected: [Entry] = []
        for chain in Chain.all {
            let tokens = TokenRegistry.tokens(for: chain)
            let balances = await fetcher.fetch(holder: holder, chain: chain, tokens: tokens)
            for token in tokens {
                if let balance = balances[token], balance > 0 {
                    collected.append(Entry(chain: chain, token: token, balance: balance))
                }
            }
        }
        self.entries = collected
        self.isLoading = false
    }
}
