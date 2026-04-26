import SwiftUI

/// Resolution-behavior settings: how ENS names get resolved (quorum,
/// safety interstitial, off-chain CCIP). The infrastructure layer
/// (which RPC URLs we hit, custom RPC override) lives on the RPC page.
struct ENSSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
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
                Text("Quorum")
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
