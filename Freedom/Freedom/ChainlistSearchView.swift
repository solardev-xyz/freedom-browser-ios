import SwiftUI

/// Browse chainlist.org's catalogue and pre-fill `AddChainForm` from
/// a selection. Pushed onto the settings nav stack — tapping a result
/// pushes the form with the chain's metadata populated; the back arrow
/// returns here. A toolbar "Manual" link pushes an empty form for
/// chains chainlist doesn't carry.
struct ChainlistSearchView: View {
    @State private var allChains: [ChainlistService.ImportableChain] = []
    @State private var loadState: LoadState = .loading
    @State private var query: String = ""

    /// Owned-per-sheet — each "Search Chainlist" open does its own
    /// cache lookup. Cache is shared at the disk layer, so reopens
    /// after the first within a TTL window are sub-second.
    private let service = ChainlistService()

    private enum LoadState {
        case loading
        case loaded
        case failed(String)
    }

    private var filteredChains: [ChainlistService.ImportableChain] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return allChains }
        return allChains.filter {
            $0.displayName.lowercased().contains(q) || String($0.chainID).contains(q)
        }
    }

    var body: some View {
        content
            .navigationTitle("Add from Chainlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: SettingsPath.addChainForm(nil)) {
                        Text("Manual")
                    }
                }
            }
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading chainlist…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Retry") {
                    Task { await load() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            List {
                ForEach(filteredChains, id: \.chainID) { chain in
                    NavigationLink(value: SettingsPath.addChainForm(makePrefill(chain))) {
                        chainRow(chain)
                    }
                }
            }
            .searchable(text: $query, prompt: "Name or chain ID")
            .overlay {
                if filteredChains.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }

    private func chainRow(_ chain: ChainlistService.ImportableChain) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(chain.displayName)
            Text("Chain \(chain.chainID) · \(chain.rpcURLs.count) provider\(chain.rpcURLs.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func makePrefill(_ chain: ChainlistService.ImportableChain) -> AddChainForm.Prefill {
        AddChainForm.Prefill(
            chainID: chain.chainID,
            displayName: chain.displayName,
            nativeName: chain.nativeName,
            nativeSymbol: chain.nativeSymbol,
            nativeDecimals: chain.nativeDecimals,
            explorerBase: chain.explorerBase ?? "",
            rpcURLs: chain.rpcURLs
        )
    }

    private func load() async {
        loadState = .loading
        do {
            allChains = try await service.chains()
            loadState = .loaded
        } catch {
            loadState = .failed("Couldn't load chainlist. Check your connection and try again.")
        }
    }
}
