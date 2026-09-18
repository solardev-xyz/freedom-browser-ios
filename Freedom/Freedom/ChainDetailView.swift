import MyotisKit
import SwiftUI

/// Settings → Chains → chain: the chain's routing policy and endpoints
/// (desktop's per-chain page). Read and verification order with a
/// switch and the source's own settings per row, transaction broadcast
/// order, the user's endpoints above the shipped public ones, and
/// removal for custom chains. Every edit writes through `ChainStore`;
/// the pool's shuffle + quarantine reset happens at
/// `SettingsView.finish()`.
struct ChainDetailView: View {
    let chain: Chain

    @Environment(ChainStore.self) private var chainStore
    @Environment(SettingsStore.self) private var settings
    @Environment(MyotisNode.self) private var myotis
    @Environment(\.settingsPath) private var settingsPath

    @State private var policy: ChainAccessPolicy
    /// Every supported read source in display order — the enabled ones
    /// (the policy's `readOrder`) followed by the disabled ones. Only
    /// the enabled order is persisted; a disabled source keeps its
    /// on-screen slot until it is switched on.
    @State private var readSources: [ChainSource]
    @State private var broadcastSources: [ChainSource]
    @State private var newProviderText = ""
    @State private var confirmRemove = false

    init(chain: Chain, chainStore: ChainStore) {
        self.chain = chain
        let policy = chainStore.policy(forChainID: chain.id)
        _policy = State(initialValue: policy)
        _readSources = State(initialValue: Self.displayOrder(policy.readOrder, supported: ChainAccessPolicy.supportedSources(forChainID: chain.id)))
        _broadcastSources = State(initialValue: Self.displayOrder(
            policy.broadcastOrder, supported: ChainAccessPolicy.supportedSources(forChainID: chain.id).filter(\.canBroadcast)
        ))
    }

    private static func displayOrder(_ enabled: [ChainSource], supported: [ChainSource]) -> [ChainSource] {
        enabled.filter(supported.contains) + supported.filter { !enabled.contains($0) }
    }

    private var urls: [String] { chainStore.rpcURLs(forChainID: chain.id) }
    private var defaults: [String] { chainStore.defaultRPCURLs(forChainID: chain.id) }
    private var mine: [String] { chainStore.userAddedRPCURLs(forChainID: chain.id) }
    private var publicURLs: [String] { urls.filter { !mine.contains($0) } }
    private var isLightClientChain: Bool { ChainAccessPolicy.lightClientChainIDs.contains(chain.id) }

    var body: some View {
        Form {
            Section {
                ForEach(readSources) { source in
                    readRow(source)
                }
            } header: {
                Text("Read and verification order")
            } footer: {
                Text("Freedom routes wallet, transaction and dapp reads through the sources above, top to bottom. A source that cannot serve a request falls through to the next one.")
            }

            Section {
                ForEach(broadcastSources) { source in
                    broadcastRow(source)
                }
            } header: {
                Text("Transaction broadcast")
            } footer: {
                Text(isLightClientChain
                     ? "Signed transactions go out over P2P first, with RPC as the compatibility fallback."
                     : "Signed transactions go to the first configured endpoint that accepts them.")
            }

            Section {
                if mine.isEmpty {
                    Text("No custom RPCs yet").foregroundStyle(.secondary).font(.caption)
                }
                ForEach(mine, id: \.self) { url in
                    endpointRow(url)
                }
                .onDelete { remove(at: $0, from: mine) }
                HStack {
                    TextField("https://your-node.example", text: $newProviderText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.caption).monospaced()
                    Button { addProvider() } label: {
                        Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                    }
                    .disabled(newProviderText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Your RPCs")
            } footer: {
                Text("Endpoints you added — tried first on the direct tier, and answers from them are labelled as your own.")
            }

            Section {
                ForEach(publicURLs, id: \.self) { url in
                    endpointRow(url)
                }
                .onDelete { remove(at: $0, from: publicURLs) }
                if !defaults.isEmpty, urls != defaults {
                    Button("Reset to defaults", role: .destructive) {
                        chainStore.resetRPCURLs(forChainID: chain.id)
                    }
                }
            } header: {
                Text("Public RPCs")
            } footer: {
                Text("Free public endpoints — the always-on fallback. Distinct URLs don't guarantee distinct operators; several may proxy the same backend.")
            }

            if !chain.isBuiltIn {
                Section {
                    Button("Remove this chain", role: .destructive) { confirmRemove = true }
                }
            }
        }
        .navigationTitle(chain.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: policy) { _, updated in
            chainStore.updatePolicy(forChainID: chain.id, updated)
        }
        .confirmationDialog("Remove \(chain.displayName)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                removeChain()
            }
        } message: {
            Text("Its RPC endpoints and routing policy are deleted. Sites connected on this chain keep their permissions.")
        }
    }

    // MARK: - Source rows

    @ViewBuilder
    private func readRow(_ source: ChainSource) -> some View {
        let enabled = policy.readOrder.contains(source)
        HStack(alignment: .top, spacing: 8) {
            orderButtons(for: source, in: $readSources, enabledOrder: \.readOrder)
            ChainSourceRows.Row(
                title: readTitle(source),
                help: readHelp(source),
                badge: readBadge(source),
                isOn: Binding(
                    get: { enabled },
                    set: { setRead(source, enabled: $0) }
                ),
                canDisable: policy.readOrder.count > 1
            ) {
                switch source {
                case .myotis:
                    NavigationLink(value: SettingsPath.myotis) {
                        Text("Node settings").font(.caption)
                    }
                case .colibri:
                    ChainSourceRows.ColibriFields(policy: $policy, placeholder: defaultProver)
                case .quorum:
                    ChainSourceRows.QuorumFields(policy: $policy, available: urls.count)
                case .direct:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private func broadcastRow(_ source: ChainSource) -> some View {
        let enabled = policy.broadcastOrder.contains(source)
        HStack(alignment: .top, spacing: 8) {
            orderButtons(for: source, in: $broadcastSources, enabledOrder: \.broadcastOrder)
            ChainSourceRows.Row(
                title: source == .myotis ? "Myotis P2P broadcast" : "Direct RPC",
                help: source == .myotis
                    ? "Handed to the embedded light client's peers over devp2p — no RPC endpoint sees the transaction. An uncertain outcome is never retried elsewhere."
                    : "Sent to the first configured endpoint that accepts it.",
                badge: source == .myotis
                    ? ChainSourceRows.myotisBadge(chainID: chain.id, node: myotis, enabled: settings.myotisNodeEnabled)
                    : ChainSourceRows.Badge(text: urls.isEmpty ? "No endpoints" : "\(urls.count) endpoint\(urls.count == 1 ? "" : "s")", kind: urls.isEmpty ? .warning : .neutral),
                isOn: Binding(
                    get: { enabled },
                    set: { setBroadcast(source, enabled: $0) }
                ),
                canDisable: policy.broadcastOrder.count > 1
            ) {
                EmptyView()
            }
        }
    }

    /// Up / down arrows that move a source within its list and rewrite
    /// the persisted order from the enabled entries.
    private func orderButtons(
        for source: ChainSource,
        in list: Binding<[ChainSource]>,
        enabledOrder: WritableKeyPath<ChainAccessPolicy, [ChainSource]>
    ) -> some View {
        let index = list.wrappedValue.firstIndex(of: source) ?? 0
        return VStack(spacing: 6) {
            Button {
                move(source, by: -1, in: list, enabledOrder: enabledOrder)
            } label: {
                Image(systemName: "chevron.up").font(.caption2)
            }
            .disabled(index == 0)
            Text("\(index + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            Button {
                move(source, by: 1, in: list, enabledOrder: enabledOrder)
            } label: {
                Image(systemName: "chevron.down").font(.caption2)
            }
            .disabled(index == list.wrappedValue.count - 1)
        }
        .buttonStyle(.borderless)
        .frame(width: 24)
    }

    private func move(
        _ source: ChainSource,
        by delta: Int,
        in list: Binding<[ChainSource]>,
        enabledOrder: WritableKeyPath<ChainAccessPolicy, [ChainSource]>
    ) {
        var sources = list.wrappedValue
        guard let index = sources.firstIndex(of: source) else { return }
        let target = index + delta
        guard sources.indices.contains(target) else { return }
        sources.swapAt(index, target)
        list.wrappedValue = sources
        let enabled = Set(policy[keyPath: enabledOrder])
        policy[keyPath: enabledOrder] = sources.filter(enabled.contains)
    }

    private func setRead(_ source: ChainSource, enabled: Bool) {
        var set = Set(policy.readOrder)
        if enabled { set.insert(source) } else if set.count > 1 { set.remove(source) }
        policy.readOrder = readSources.filter(set.contains)
    }

    private func setBroadcast(_ source: ChainSource, enabled: Bool) {
        var set = Set(policy.broadcastOrder)
        if enabled { set.insert(source) } else if set.count > 1 { set.remove(source) }
        policy.broadcastOrder = broadcastSources.filter(set.contains)
    }

    private func readTitle(_ source: ChainSource) -> String {
        switch source {
        case .myotis: "Myotis P2P light client"
        case .colibri: "Colibri cryptographic verification"
        case .quorum: "RPC quorum"
        case .direct: "Direct RPC"
        }
    }

    private func readHelp(_ source: ChainSource) -> String {
        switch source {
        case .myotis: "Verified locally against the chain; no RPC endpoint involved."
        case .colibri: "Verifies prover responses against the chain consensus."
        case .quorum: "Requires matching responses from independently configured RPC endpoints."
        case .direct: "Compatibility fallback using the first working configured endpoint. Not cryptographic verification."
        }
    }

    private func readBadge(_ source: ChainSource) -> ChainSourceRows.Badge {
        switch source {
        case .myotis:
            return ChainSourceRows.myotisBadge(chainID: chain.id, node: myotis, enabled: settings.myotisNodeEnabled)
        case .colibri:
            return ChainSourceRows.Badge(text: "Verified", kind: .ready)
        case .quorum:
            return ChainSourceRows.quorumBadge(m: policy.quorumM, k: policy.quorumK, available: urls.count)
        case .direct:
            return mine.isEmpty
                ? ChainSourceRows.Badge(text: "Public endpoint", kind: .neutral)
                : ChainSourceRows.Badge(text: "Your endpoint", kind: .ready)
        }
    }

    private var defaultProver: String {
        chain.id == Chain.mainnetID ? ColibriENSClient.defaultProverURL : "corpus.core default"
    }

    // MARK: - Endpoints

    private func endpointRow(_ url: String) -> some View {
        Text(url).font(.caption).monospaced().lineLimit(1).truncationMode(.middle)
    }

    /// Refuse-to-save-empty: a chain with no endpoints would throw
    /// `noProviders` on every read. The last row cannot be deleted.
    private func remove(at offsets: IndexSet, from list: [String]) {
        let removed = Set(offsets.compactMap { list.indices.contains($0) ? list[$0] : nil })
        let next = urls.filter { !removed.contains($0) }
        guard !next.isEmpty else { return }
        chainStore.updateRPCURLs(forChainID: chain.id, next)
    }

    private func addProvider() {
        let trimmed = newProviderText.trimmingCharacters(in: .whitespacesAndNewlines)
        newProviderText = ""
        guard !trimmed.isEmpty else { return }
        // Case-insensitive dedupe matches the pool's normalization.
        let existing = Set(urls.map { $0.lowercased() })
        guard !existing.contains(trimmed.lowercased()) else { return }
        // The user's endpoints go first: the direct tier walks the list
        // in order and their answer is labelled as their own.
        chainStore.updateRPCURLs(forChainID: chain.id, [trimmed] + urls)
    }

    private func removeChain() {
        let activeID = UserDefaults.standard.integer(forKey: WalletDefaults.activeChainID)
        chainStore.deleteChain(id: chain.id)
        if activeID == chain.id {
            WalletDefaults.setActiveChainID(Chain.defaultChain.id)
        }
        settingsPath.wrappedValue.removeAll { if case .chainEditor = $0 { return true } else { return false } }
    }
}
