import MyotisKit
import SwiftUI

/// Settings → Chains → chain: the chain's routing policy and endpoints
/// (desktop's per-chain page). Read and verification order and the
/// broadcast order are drag-to-reorder lists with a switch per source;
/// tapping a read source opens its options (`ChainSourceDetailView`).
/// The user's endpoints sit above the shipped public ones; custom
/// chains can be removed. Every edit writes through `ChainStore`; the
/// pool's shuffle + quarantine reset happens at `SettingsView.finish()`.
struct ChainDetailView: View {
    let chain: Chain

    @Environment(ChainStore.self) private var chainStore
    @Environment(SettingsStore.self) private var settings
    @Environment(MyotisNode.self) private var myotis
    @Environment(\.settingsPath) private var settingsPath

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
        let supported = ChainAccessPolicy.supportedSources(forChainID: chain.id)
        _readSources = State(initialValue: Self.displayOrder(policy.readOrder, supported: supported))
        _broadcastSources = State(initialValue: Self.displayOrder(policy.broadcastOrder, supported: supported.filter(\.canBroadcast)))
    }

    private static func displayOrder(_ enabled: [ChainSource], supported: [ChainSource]) -> [ChainSource] {
        enabled.filter(supported.contains) + supported.filter { !enabled.contains($0) }
    }

    /// Always the stored policy, so an edit made on a source's option
    /// page is what this page shows when the user comes back.
    private var policy: ChainAccessPolicy { chainStore.policy(forChainID: chain.id) }
    private var urls: [String] { chainStore.rpcURLs(forChainID: chain.id) }
    private var defaults: [String] { chainStore.defaultRPCURLs(forChainID: chain.id) }
    private var mine: [String] { chainStore.userAddedRPCURLs(forChainID: chain.id) }
    private var publicURLs: [String] { urls.filter { !mine.contains($0) } }
    private var isLightClientChain: Bool { ChainAccessPolicy.lightClientChainIDs.contains(chain.id) }

    var body: some View {
        Form {
            Section {
                ForEach(readSources) { source in
                    NavigationLink(value: SettingsPath.chainSource(chain.id, source)) {
                        ChainSourceRows.Row(
                            title: ChainSourceRows.readTitle(source),
                            badge: readBadge(source),
                            isOn: Binding(
                                get: { policy.readOrder.contains(source) },
                                set: { setRead(source, enabled: $0) }
                            ),
                            canDisable: policy.readOrder.count > 1
                        )
                    }
                }
                .onMove { from, to in
                    readSources.move(fromOffsets: from, toOffset: to)
                    var updated = policy
                    updated.readOrder = readSources.filter(policy.readOrder.contains)
                    chainStore.updatePolicy(forChainID: chain.id, updated)
                }
            } header: {
                Text("Read and verification order")
            } footer: {
                Text("Freedom routes wallet, transaction and dapp reads through the sources above, top to bottom. A source that cannot serve a request falls through to the next one. Drag to reorder; tap a source for its options.")
            }

            Section {
                ForEach(broadcastSources) { source in
                    ChainSourceRows.Row(
                        title: source == .myotis ? "Myotis P2P broadcast" : "Direct RPC",
                        badge: broadcastBadge(source),
                        isOn: Binding(
                            get: { policy.broadcastOrder.contains(source) },
                            set: { setBroadcast(source, enabled: $0) }
                        ),
                        canDisable: policy.broadcastOrder.count > 1
                    )
                }
                .onMove { from, to in
                    broadcastSources.move(fromOffsets: from, toOffset: to)
                    var updated = policy
                    updated.broadcastOrder = broadcastSources.filter(policy.broadcastOrder.contains)
                    chainStore.updatePolicy(forChainID: chain.id, updated)
                }
            } header: {
                Text("Transaction broadcast")
            } footer: {
                Text(isLightClientChain
                     ? "Signed transactions go to the embedded light client's peers over devp2p first, with RPC as the compatibility fallback. An uncertain P2P outcome is never retried elsewhere."
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
        .toolbar { EditButton() }
        .confirmationDialog("Remove \(chain.displayName)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { removeChain() }
        } message: {
            Text("Its RPC endpoints and routing policy are deleted. Sites connected on this chain keep their permissions.")
        }
    }

    // MARK: - Sources

    private func setRead(_ source: ChainSource, enabled: Bool) {
        var set = Set(policy.readOrder)
        if enabled { set.insert(source) } else if set.count > 1 { set.remove(source) }
        var updated = policy
        updated.readOrder = readSources.filter(set.contains)
        chainStore.updatePolicy(forChainID: chain.id, updated)
    }

    private func setBroadcast(_ source: ChainSource, enabled: Bool) {
        var set = Set(policy.broadcastOrder)
        if enabled { set.insert(source) } else if set.count > 1 { set.remove(source) }
        var updated = policy
        updated.broadcastOrder = broadcastSources.filter(set.contains)
        chainStore.updatePolicy(forChainID: chain.id, updated)
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

    private func broadcastBadge(_ source: ChainSource) -> ChainSourceRows.Badge {
        if source == .myotis {
            return ChainSourceRows.myotisBadge(chainID: chain.id, node: myotis, enabled: settings.myotisNodeEnabled)
        }
        return urls.isEmpty
            ? ChainSourceRows.Badge(text: "No endpoints", kind: .warning)
            : ChainSourceRows.Badge(text: "\(urls.count) endpoint\(urls.count == 1 ? "" : "s")", kind: .neutral)
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

/// Settings → Chains → chain → source: the switch, what the source is,
/// its status, and its own settings (Colibri prover + ZK, quorum M of K
/// + timeout, Direct RPC's endpoints).
struct ChainSourceDetailView: View {
    let chain: Chain
    let source: ChainSource

    @Environment(ChainStore.self) private var chainStore
    @Environment(SettingsStore.self) private var settings
    @Environment(MyotisNode.self) private var myotis

    private var policy: ChainAccessPolicy { chainStore.policy(forChainID: chain.id) }
    private var urls: [String] { chainStore.rpcURLs(forChainID: chain.id) }
    private var mine: [String] { chainStore.userAddedRPCURLs(forChainID: chain.id) }

    /// Edits go straight to the store; the store's version bump
    /// refreshes every reader, including the order page behind this one.
    private var policyBinding: Binding<ChainAccessPolicy> {
        Binding(
            get: { chainStore.policy(forChainID: chain.id) },
            set: { chainStore.updatePolicy(forChainID: chain.id, $0) }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { policy.readOrder.contains(source) },
                    set: { setEnabled($0) }
                )) {
                    HStack(spacing: 10) {
                        Text("Enabled")
                        badge
                    }
                }
                .disabled(policy.readOrder == [source])
            } footer: {
                Text(ChainSourceRows.readHelp(source))
            }

            switch source {
            case .myotis:
                Section {
                    NavigationLink(value: SettingsPath.myotis) {
                        Label("Node settings", systemImage: "bolt.shield")
                    }
                } footer: {
                    Text(ChainAccessPolicy.lightClientChainIDs.contains(chain.id)
                         ? "Reads are served once the light client reports itself synced with a snap peer for this chain; until then the next source answers."
                         : "The light client does not cover this chain.")
                }
            case .colibri:
                Section {
                    ChainSourceRows.ColibriFields(policy: policyBinding, placeholder: defaultProver)
                } header: {
                    Text("Prover")
                } footer: {
                    Text(chain.id == Chain.mainnetID
                         ? "Leave the prover empty for the corpus.core default. ZK proof bootstraps the sync committee from a succinct proof instead of trusted checkpoints. These are also the Name Resolution page's Colibri settings."
                         : "Leave the prover empty for the corpus.core default for this chain. ZK proof bootstraps the sync committee from a succinct proof instead of trusted checkpoints.")
                }
            case .quorum:
                Section {
                    ChainSourceRows.QuorumFields(policy: policyBinding, available: urls.count)
                } header: {
                    Text("Agreement threshold")
                } footer: {
                    Text("Require matching responses from independently configured RPC endpoints. \(urls.count) endpoint\(urls.count == 1 ? "" : "s") currently available; verified quorum needs at least \(AnchorCorroboration.minQuorumProviders). The timeout also bounds every other source's wait.\(chain.id == Chain.mainnetID ? " These are also the Name Resolution page's quorum settings." : "")")
                }
            case .direct:
                Section {
                    ForEach(urls, id: \.self) { url in
                        HStack {
                            Text(url).font(.caption).monospaced().lineLimit(1).truncationMode(.middle)
                            if mine.contains(url) {
                                Spacer()
                                ChainSourceRows.Badge(text: "Yours", kind: .ready)
                            }
                        }
                    }
                } header: {
                    Text("Endpoints, in order")
                } footer: {
                    Text("The first endpoint that answers is used. Your own endpoints come first and their answers are labelled user-configured; a public endpoint's answer is unverified. Edit the lists on the \(chain.displayName) page.")
                }
            }
        }
        .navigationTitle(ChainSourceRows.readTitle(source))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var badge: ChainSourceRows.Badge {
        switch source {
        case .myotis:
            ChainSourceRows.myotisBadge(chainID: chain.id, node: myotis, enabled: settings.myotisNodeEnabled)
        case .colibri:
            ChainSourceRows.Badge(text: "Verified", kind: .ready)
        case .quorum:
            ChainSourceRows.quorumBadge(m: policy.quorumM, k: policy.quorumK, available: urls.count)
        case .direct:
            mine.isEmpty
                ? ChainSourceRows.Badge(text: "Public endpoint", kind: .neutral)
                : ChainSourceRows.Badge(text: "Your endpoint", kind: .ready)
        }
    }

    private var defaultProver: String {
        chain.id == Chain.mainnetID ? ColibriENSClient.defaultProverURL : "corpus.core default"
    }

    private func setEnabled(_ enabled: Bool) {
        var updated = policy
        if enabled {
            if !updated.readOrder.contains(source) { updated.readOrder.append(source) }
        } else if updated.readOrder.count > 1 {
            updated.readOrder.removeAll { $0 == source }
        }
        chainStore.updatePolicy(forChainID: chain.id, updated)
    }
}
