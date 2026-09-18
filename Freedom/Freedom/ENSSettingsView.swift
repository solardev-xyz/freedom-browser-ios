import MyotisKit
import SwiftUI

/// Name resolution — how `.eth`, `.box`, `.wei` and `.gwei` names get
/// resolved (desktop's "Name Resolution" page): the resolution order
/// with a switch and its own settings per method, "prefer verified",
/// the unverified-answer safety gate and off-chain CCIP. The mainnet
/// endpoints those methods use live under Chains → Ethereum.
struct ENSSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ChainStore.self) private var chainStore
    @Environment(MyotisNode.self) private var myotis

    private var mainnetEndpoints: Int { chainStore.rpcURLs(forChainID: Chain.mainnetID).count }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                ForEach(settings.ensResolutionOrder, id: \.self) { method in
                    methodRow(method)
                }
                Toggle("Prefer verified answers", isOn: $settings.ensPreferVerified)
            } header: {
                Text("Resolution order")
            } footer: {
                Text("Freedom tries enabled methods from top to bottom. With \"Prefer verified answers\" on, an unverified Direct RPC answer is kept as a fallback while later methods try to produce a verified one. These records live on Ethereum — manage endpoints under Chains → Ethereum.")
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
    }

    // MARK: - Rows

    @ViewBuilder
    private func methodRow(_ method: ENSResolutionMethod) -> some View {
        @Bindable var settings = settings
        let enabled = settings.ensResolutionEnabled.contains(method)
        HStack(alignment: .top, spacing: 8) {
            orderButtons(for: method)
            ChainSourceRows.Row(
                title: title(method),
                help: help(method),
                badge: badge(method),
                isOn: Binding(
                    get: { enabled },
                    set: { on in
                        if on || settings.ensResolutionEnabled.count > 1 {
                            settings.setResolutionMethod(method, enabled: on)
                        }
                    }
                ),
                canDisable: settings.ensResolutionEnabled.count > 1
            ) {
                switch method {
                case .myotis:
                    NavigationLink(value: SettingsPath.myotis) {
                        Text("Node settings").font(.caption)
                    }
                case .colibri:
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Prover") {
                            TextField(ColibriENSClient.defaultProverURL, text: $settings.ensColibriProverUrl)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .font(.caption).monospaced()
                                .multilineTextAlignment(.trailing)
                        }
                        Toggle("ZK consensus proof", isOn: $settings.ensColibriZkProof)
                        Text("Leave the prover empty for the corpus.core default. ZK proof bootstraps the sync committee from a succinct proof instead of trusted checkpoints.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                case .quorum:
                    VStack(alignment: .leading, spacing: 6) {
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
                        Picker("Block anchor", selection: $settings.ensBlockAnchor) {
                            Text("latest").tag(BlockAnchor.latest)
                            Text("latest-32").tag(BlockAnchor.latestMinus32)
                            Text("finalized").tag(BlockAnchor.finalized)
                        }
                        LabeledContent("Anchor TTL") {
                            ChainSourceRows.NumericField(value: $settings.ensBlockAnchorTtlMs, suffix: "ms")
                        }
                        Text("Byte-identical answers at one corroborated block. \(mainnetEndpoints) endpoint\(mainnetEndpoints == 1 ? "" : "s") currently available; verified quorum needs at least \(AnchorCorroboration.minQuorumProviders). These are Ethereum's chain settings — the wallet's reads share them.")
                            .font(.caption2).foregroundStyle(.secondary)
                        NavigationLink(value: SettingsPath.chainEditor(Chain.mainnetID)) {
                            Text("Manage endpoints").font(.caption)
                        }
                    }
                    .font(.callout)
                case .userConfigured:
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("https://your-node.example (optional)", text: $settings.ensRpcUrl)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(.caption).monospaced()
                        Text("With your own endpoint set, answers are labelled \"user-configured\". Without one, the first public endpoint that answers is used and the answer is unverified.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                case .direct:
                    EmptyView()
                }
            }
        }
    }

    private func orderButtons(for method: ENSResolutionMethod) -> some View {
        let order = settings.ensResolutionOrder
        let index = order.firstIndex(of: method) ?? 0
        return VStack(spacing: 6) {
            Button { move(method, by: -1) } label: {
                Image(systemName: "chevron.up").font(.caption2)
            }
            .disabled(index == 0)
            Text("\(index + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            Button { move(method, by: 1) } label: {
                Image(systemName: "chevron.down").font(.caption2)
            }
            .disabled(index == order.count - 1)
        }
        .buttonStyle(.borderless)
        .frame(width: 24)
    }

    private func move(_ method: ENSResolutionMethod, by delta: Int) {
        var order = settings.ensResolutionOrder
        guard let index = order.firstIndex(of: method), order.indices.contains(index + delta) else { return }
        order.swapAt(index, index + delta)
        settings.setResolutionOrder(order)
    }

    private func title(_ method: ENSResolutionMethod) -> String {
        switch method {
        case .myotis: "Myotis light client"
        case .colibri: "Colibri"
        case .quorum: "RPC quorum"
        case .userConfigured, .direct: "Direct RPC"
        }
    }

    private func help(_ method: ENSResolutionMethod) -> String {
        switch method {
        case .myotis: "Local P2P resolution. ENS prefers finalized state; newer ENS records and WNS/GNS use a cryptographically verified optimistic beacon head."
        case .colibri: "A remote prover produces the witness; Freedom verifies the cryptographic proof locally."
        case .quorum: "Multiple independent RPC endpoints must return byte-identical answers at one anchored block."
        case .userConfigured, .direct: "Uses one endpoint — your own if configured. This is not cryptographic verification and is off by default."
        }
    }

    private func badge(_ method: ENSResolutionMethod) -> ChainSourceRows.Badge {
        switch method {
        case .myotis:
            return ChainSourceRows.myotisBadge(chainID: Chain.mainnetID, node: myotis, enabled: settings.myotisNodeEnabled)
        case .colibri:
            return ChainSourceRows.Badge(text: "Verified", kind: .ready)
        case .quorum:
            return ChainSourceRows.quorumBadge(m: settings.ensQuorumM, k: settings.ensQuorumK, available: mainnetEndpoints)
        case .userConfigured, .direct:
            return settings.ensRpcUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ChainSourceRows.Badge(text: "Public endpoint", kind: .neutral)
                : ChainSourceRows.Badge(text: "Your endpoint", kind: .ready)
        }
    }
}
