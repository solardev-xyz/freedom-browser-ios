import SwiftUI

/// Per-chain RPC provider editor. Mirrors the shape of the pre-Phase-2
/// flat `RPCSettingsView` (rows + inline add + reset-to-defaults) but
/// parameterized by a `Chain` and writing through `ChainStore`. The
/// pool's shuffle + quarantine reset happens at `SettingsView.finish()`
/// — not on every per-row edit — so a user mid-edit doesn't get their
/// pool state thrashed on each keystroke.
struct ChainRPCDetailView: View {
    let chain: Chain

    @Environment(ChainStore.self) private var chainStore

    @State private var newProviderText: String = ""

    private var urls: [String] { chainStore.rpcURLs(forChainID: chain.id) }

    /// Seed defaults for the built-in chains so the reset button can put
    /// them back. Custom chains have no defaults — the reset button is
    /// hidden for them.
    private var defaults: [String]? {
        guard chain.isBuiltIn else { return nil }
        switch chain.id {
        case Chain.mainnetID: return SettingsStore.defaultPublicRpcProviders
        case Chain.gnosisID: return ChainRegistry.gnosisURLs.map(\.absoluteString)
        default: return nil
        }
    }

    var body: some View {
        Form {
            Section {
                ForEach(urls, id: \.self) { url in
                    Text(url).font(.caption).monospaced().lineLimit(1).truncationMode(.middle)
                }
                .onDelete(perform: deleteProviders)
                HStack {
                    TextField("https://new-provider.example", text: $newProviderText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.caption).monospaced()
                    Button {
                        addProvider()
                    } label: {
                        Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                    }
                    .disabled(newProviderText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let defaults, urls != defaults {
                    Button("Reset to defaults", role: .destructive) {
                        chainStore.updateRPCURLs(forChainID: chain.id, defaults)
                    }
                }
            } header: {
                Text("\(chain.displayName) Providers")
            } footer: {
                Text("At least one provider is required. Distinct URLs don't guarantee distinct operators — several may proxy the same backend.")
            }
        }
        .navigationTitle(chain.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Refuse-to-save-empty (roadmap §10): a chain with no providers
    /// would either silently fall back to mainnet defaults (wrong for
    /// any non-mainnet chain) or throw `noProviders` on every wallet
    /// read. Block the last-row delete at the editor.
    private func deleteProviders(at offsets: IndexSet) {
        var copy = urls
        copy.remove(atOffsets: offsets)
        guard !copy.isEmpty else { return }
        chainStore.updateRPCURLs(forChainID: chain.id, copy)
    }

    private func addProvider() {
        let trimmed = newProviderText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            newProviderText = ""
            return
        }
        // Case-insensitive dedupe matches the pool's normalization —
        // otherwise the UI accepts two entries that collapse to one
        // downstream, which looks like state drift.
        let existing = Set(urls.map { $0.lowercased() })
        if !existing.contains(trimmed.lowercased()) {
            var next = urls
            next.append(trimmed)
            chainStore.updateRPCURLs(forChainID: chain.id, next)
        }
        newProviderText = ""
    }
}
