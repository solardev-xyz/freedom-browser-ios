import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ENSResolver.self) private var resolver
    @Environment(\.dismiss) private var dismiss

    @State private var newProviderText: String = ""

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    Toggle("Use custom RPC", isOn: $settings.enableEnsCustomRpc)
                    TextField("https://your-node.example", text: $settings.ensRpcUrl)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.caption).monospaced()
                        .disabled(!settings.enableEnsCustomRpc)
                } header: {
                    Text("Custom RPC")
                } footer: {
                    Text("When enabled, Freedom uses your own Ethereum node for ENS resolution. Trust label becomes \"user-configured\" — single-source, not cross-checked.")
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
                    Text("Quorum")
                } footer: {
                    Text("M-of-K public RPCs must return byte-identical responses at a corroborated block. K<3 or M<2 falls through to single-source unverified.")
                }

                Section {
                    ForEach(settings.ensPublicRpcProviders, id: \.self) { url in
                        Text(url).font(.caption).monospaced().lineLimit(1).truncationMode(.middle)
                    }
                    .onDelete { offsets in
                        settings.ensPublicRpcProviders.remove(atOffsets: offsets)
                    }
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
                    if settings.ensPublicRpcProviders != SettingsStore.defaultPublicRpcProviders {
                        Button("Reset to defaults", role: .destructive) {
                            settings.ensPublicRpcProviders = SettingsStore.defaultPublicRpcProviders
                        }
                    }
                } header: {
                    Text("Public RPC Providers")
                } footer: {
                    Text("Used when custom RPC is off. Distinct URLs don't guarantee distinct operators — several of the defaults may proxy the same backend.")
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
                    Text("Advanced")
                } footer: {
                    Text("Some ENS names (e.g. .box via 3DNS) resolve via an offchain gateway. When on, the browser follows the OffchainLookup revert, fetches from the gateway the resolver specifies, and re-verifies the callback at the pinned block. Off by default — the gateway sees the queried name.")
                }

                Section("About") {
                    Link(destination: URL(string: "https://docs.ens.domains/resolvers/universal/")!) {
                        LabeledContent("Universal Resolver", value: "docs.ens.domains")
                    }
                    Link(destination: URL(string: "https://docs.ens.domains/ensip/15")!) {
                        LabeledContent("ENSIP-15 normalization", value: "docs.ens.domains")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { finish() }
                }
            }
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

    private func addProvider() {
        let trimmed = newProviderText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            newProviderText = ""
            return
        }
        // Case-insensitive dedupe matches the pool's own normalization —
        // otherwise the UI lets users add two entries that collapse to
        // one downstream, which looks like state drift.
        let existingLowers = Set(settings.ensPublicRpcProviders.map { $0.lowercased() })
        if !existingLowers.contains(trimmed.lowercased()) {
            settings.ensPublicRpcProviders.append(trimmed)
        }
        newProviderText = ""
    }

    private func finish() {
        // Settings changes invalidate the pool shuffle + quarantine and the
        // resolver cache so the next navigation runs against the new config.
        resolver.invalidate()
        dismiss()
    }
}
