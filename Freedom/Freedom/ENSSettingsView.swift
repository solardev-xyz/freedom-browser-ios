import MyotisKit
import SwiftUI

/// Name resolution — how `.eth`, `.box`, `.wei` and `.gwei` names get
/// resolved (desktop's "Name Resolution" page): a drag-to-reorder
/// resolution order with a switch per method (tap a method for its
/// options), "prefer verified", the unverified-answer safety gate and
/// off-chain CCIP. The mainnet endpoints those methods use live under
/// Chains → Ethereum.
struct ENSSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ChainStore.self) private var chainStore
    @Environment(MyotisNode.self) private var myotis
    @Environment(\.settingsPath) private var settingsPath

    private var mainnetEndpoints: Int { chainStore.rpcURLs(forChainID: Chain.mainnetID).count }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                ForEach(settings.ensResolutionOrder, id: \.self) { method in
                    ChainSourceRows.Row(
                        title: ENSMethodDetailView.title(method),
                        badge: ENSMethodDetailView.badge(method, settings: settings, myotis: myotis, endpoints: mainnetEndpoints),
                        isOn: Binding(
                            get: { settings.ensResolutionEnabled.contains(method) },
                            set: { on in
                                if on || settings.ensResolutionEnabled.count > 1 {
                                    settings.setResolutionMethod(method, enabled: on)
                                }
                            }
                        ),
                        canDisable: settings.ensResolutionEnabled.count > 1,
                        open: { settingsPath.wrappedValue.append(.ensMethod(method)) }
                    )
                }
                .onMove { from, to in
                    var order = settings.ensResolutionOrder
                    order.move(fromOffsets: from, toOffset: to)
                    settings.setResolutionOrder(order)
                }
            } header: {
                Text("Resolution order")
            } footer: {
                Text("Freedom tries enabled methods from top to bottom. Drag the handles to reorder; tap a method for its options.")
            }

            Section {
                Toggle("Prefer verified answers", isOn: $settings.ensPreferVerified)
            } footer: {
                Text("Keep an unverified Direct RPC answer as a fallback while later enabled methods try to produce a verified one.")
            }

            Section {
                Toggle("Block unverified resolutions", isOn: $settings.blockUnverifiedEns)
            } header: {
                Text("Safety")
            } footer: {
                Text("When on, a resolution that came from only one endpoint shows an interstitial and requires tapping \"Continue once\" before loading. Unverified answers always keep the amber shield.")
            }

            Section {
                Toggle("Follow CCIP-Read (EIP-3668)", isOn: $settings.enableCcipRead)
            } header: {
                Text("Off-chain resolution")
            } footer: {
                Text("Some ENS names (e.g. .box via 3DNS, primary names via Namestone) resolve via an offchain gateway. When on, the browser follows the OffchainLookup revert, fetches from the gateway the resolver specifies, and re-verifies the callback at the pinned block. The gateway sees the queried name.")
            }

            Section("Docs") {
                Link(destination: URL(string: "https://docs.ens.domains/resolvers/universal/")!) {
                    LabeledContent("Universal Resolver", value: "docs.ens.domains")
                }
                Link(destination: URL(string: "https://docs.ens.domains/ensip/15")!) {
                    LabeledContent("ENSIP-15 normalization", value: "docs.ens.domains")
                }
            }
        }
        .navigationTitle("Name Resolution")
        .navigationBarTitleDisplayMode(.inline)
        // Permanent edit mode: the reorder handles are always visible.
        .environment(\.editMode, .constant(.active))
    }
}

/// Settings → Name Resolution → method: the switch, what the method
/// is, its status, and its own settings.
struct ENSMethodDetailView: View {
    let method: ENSResolutionMethod

    @Environment(SettingsStore.self) private var settings
    @Environment(ChainStore.self) private var chainStore
    @Environment(MyotisNode.self) private var myotis

    private var mainnetEndpoints: Int { chainStore.rpcURLs(forChainID: Chain.mainnetID).count }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { settings.ensResolutionEnabled.contains(method) },
                    set: { on in
                        if on || settings.ensResolutionEnabled.count > 1 {
                            settings.setResolutionMethod(method, enabled: on)
                        }
                    }
                )) {
                    HStack(spacing: 10) {
                        Text("Enabled")
                        Self.badge(method, settings: settings, myotis: myotis, endpoints: mainnetEndpoints)
                    }
                }
                .disabled(settings.ensResolutionEnabled == [method])
            } footer: {
                Text(Self.help(method))
            }

            switch method {
            case .myotis:
                Section {
                    NavigationLink(value: SettingsPath.myotis) {
                        Label("Node settings", systemImage: "bolt.shield")
                    }
                } footer: {
                    Text("Names resolve locally once the light client is synced with a snap peer; until then the next method answers.")
                }
            case .colibri:
                Section {
                    LabeledContent("Prover") {
                        TextField(ColibriENSClient.defaultProverURL, text: $settings.ensColibriProverUrl)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(.caption).monospaced()
                            .multilineTextAlignment(.trailing)
                    }
                    Toggle("ZK consensus proof", isOn: $settings.ensColibriZkProof)
                } header: {
                    Text("Prover")
                } footer: {
                    Text("Leave the prover empty for the corpus.core default. ZK proof bootstraps the sync committee from a succinct proof instead of trusted checkpoints. These are also Ethereum's Colibri settings under Chains.")
                }
            case .quorum:
                Section {
                    Stepper("Require \(settings.ensQuorumM) of \(settings.ensQuorumK)",
                            value: $settings.ensQuorumM, in: 1...max(1, settings.ensQuorumK))
                    Stepper("Endpoints per wave: \(settings.ensQuorumK)",
                            value: $settings.ensQuorumK, in: 2...9)
                        .onChange(of: settings.ensQuorumK) { _, k in
                            if settings.ensQuorumM > k { settings.ensQuorumM = k }
                        }
                    LabeledContent("Timeout") {
                        ChainSourceRows.NumericField(value: $settings.ensQuorumTimeoutMs, suffix: "ms")
                    }
                } header: {
                    Text("Agreement threshold")
                } footer: {
                    Text("Byte-identical answers at one corroborated block. \(mainnetEndpoints) endpoint\(mainnetEndpoints == 1 ? "" : "s") currently available; verified quorum needs at least \(AnchorCorroboration.minQuorumProviders). These are also Ethereum's quorum settings under Chains — the wallet's reads share them.")
                }
                Section {
                    Picker("Block anchor", selection: $settings.ensBlockAnchor) {
                        Text("latest").tag(BlockAnchor.latest)
                        Text("latest-32").tag(BlockAnchor.latestMinus32)
                        Text("finalized").tag(BlockAnchor.finalized)
                    }
                    LabeledContent("Anchor TTL") {
                        ChainSourceRows.NumericField(value: $settings.ensBlockAnchorTtlMs, suffix: "ms")
                    }
                } header: {
                    Text("Block anchor")
                } footer: {
                    Text("Every leg is asked at the same corroborated block so answers can be compared byte for byte.")
                }
                Section {
                    NavigationLink(value: SettingsPath.chainEditor(Chain.mainnetID)) {
                        Label("Manage endpoints", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
            case .userConfigured, .direct:
                Section {
                    TextField("https://your-node.example", text: $settings.ensRpcUrl)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.caption).monospaced()
                } header: {
                    Text("Your endpoint (optional)")
                } footer: {
                    Text("With your own endpoint set, answers are labelled \"user-configured\". Without one, the first public endpoint that answers is used and the answer is unverified.")
                }
                Section {
                    NavigationLink(value: SettingsPath.chainEditor(Chain.mainnetID)) {
                        Label("Manage endpoints", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
            }
        }
        .navigationTitle(Self.title(method))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Copy (shared with the order page)

    static func title(_ method: ENSResolutionMethod) -> String {
        switch method {
        case .myotis: "Myotis light client"
        case .colibri: "Colibri"
        case .quorum: "RPC quorum"
        case .userConfigured, .direct: "Direct RPC"
        }
    }

    static func help(_ method: ENSResolutionMethod) -> String {
        switch method {
        case .myotis: "Local P2P resolution. ENS prefers finalized state; newer ENS records and WNS/GNS use a cryptographically verified optimistic beacon head."
        case .colibri: "A remote prover produces the witness; Freedom verifies the cryptographic proof locally."
        case .quorum: "Multiple independent RPC endpoints must return byte-identical answers at one anchored block."
        case .userConfigured, .direct: "Uses one endpoint — your own if configured. This is not cryptographic verification and is off by default."
        }
    }

    @MainActor
    static func badge(
        _ method: ENSResolutionMethod, settings: SettingsStore, myotis: MyotisNode, endpoints: Int
    ) -> ChainSourceRows.Badge {
        switch method {
        case .myotis:
            return ChainSourceRows.myotisBadge(chainID: Chain.mainnetID, node: myotis, enabled: settings.myotisNodeEnabled)
        case .colibri:
            return ChainSourceRows.Badge(text: "Verified", kind: .ready)
        case .quorum:
            return ChainSourceRows.quorumBadge(m: settings.ensQuorumM, k: settings.ensQuorumK, available: endpoints)
        case .userConfigured, .direct:
            return settings.ensRpcUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ChainSourceRows.Badge(text: "Public endpoint", kind: .neutral)
                : ChainSourceRows.Badge(text: "Your endpoint", kind: .ready)
        }
    }
}
