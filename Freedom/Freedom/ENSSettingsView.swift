import SwiftUI

/// Resolution-behavior settings: how ENS names get resolved (method,
/// quorum tuning, safety interstitial, off-chain CCIP). The infrastructure
/// layer (which public RPC URLs we hit) lives on the RPC page.
struct ENSSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Method", selection: $settings.ensResolutionMethod) {
                    ForEach(ENSResolutionMethod.allCases, id: \.self) { method in
                        Text(method.displayName).tag(method)
                    }
                }
            } header: {
                Text("Resolution Method")
            } footer: {
                Text(methodFooter)
            }

            if settings.ensResolutionMethod == .colibri {
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
                    Toggle("Fall back to quorum", isOn: $settings.ensFallbackToQuorum)
                } header: {
                    Text("Colibri")
                } footer: {
                    Text("Each lookup is verified against the Ethereum sync committee via the prover. ZK proof bootstraps the committee from a succinct proof instead of trusted checkpoints. On a prover error, \"Fall back to quorum\" reuses the public-RPC path below rather than failing the navigation.")
                }
            }

            if settings.ensResolutionMethod == .userConfigured {
                Section {
                    TextField("https://your-node.example", text: $settings.ensRpcUrl)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.caption).monospaced()
                } header: {
                    Text("Custom RPC")
                } footer: {
                    Text("Freedom uses your own Ethereum node for ENS resolution. Trust label becomes \"user-configured\" — single-source, not cross-checked.")
                }
            }

            Section {
                Toggle("Enable quorum", isOn: $settings.enableEnsQuorum)
                Stepper("Providers per wave: \(settings.ensQuorumK)",
                        value: $settings.ensQuorumK, in: 2...9)
                Stepper("Required agreement: \(settings.ensQuorumM)",
                        value: $settings.ensQuorumM, in: 1...settings.ensQuorumK)
                LabeledContent("Timeout") {
                    numericField($settings.ensQuorumTimeoutMs, suffix: "ms")
                }
                Picker("Block anchor", selection: $settings.ensBlockAnchor) {
                    Text("latest").tag(BlockAnchor.latest)
                    Text("latest-32").tag(BlockAnchor.latestMinus32)
                    Text("finalized").tag(BlockAnchor.finalized)
                }
                LabeledContent("Anchor TTL") {
                    numericField($settings.ensBlockAnchorTtlMs, suffix: "ms")
                }
            } header: {
                Text(settings.ensResolutionMethod == .quorum ? "Quorum" : "Quorum (fallback)")
            } footer: {
                Text("M-of-K public RPCs must return byte-identical responses at a corroborated block. K<3 or M<2 falls through to single-source unverified.")
            }

            Section {
                Toggle("Block unverified resolutions", isOn: $settings.blockUnverifiedEns)
            } header: {
                Text("Safety")
            } footer: {
                Text("When on, a resolution that came from only one provider shows an interstitial and requires tapping \"Continue once\" before loading.")
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
        .navigationTitle("ENS")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var methodFooter: String {
        switch settings.ensResolutionMethod {
        case .colibri:
            return "Cryptographic verification — every lookup is proven against Ethereum consensus, not just cross-checked between RPCs."
        case .quorum:
            return "M-of-K public RPCs must agree byte-for-byte at a corroborated block."
        case .userConfigured:
            return "Resolution goes through a single Ethereum node you configure."
        }
    }

    private func numericField(_ binding: Binding<Int>, suffix: String) -> some View {
        HStack(spacing: 2) {
            TextField("", value: binding, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 60)
            Text(suffix).font(.caption).foregroundStyle(.secondary)
        }
    }
}
