import SwiftUI

/// Provider-list settings: which RPCs we hit and (optionally) a single
/// user-trusted node override. Resolution behavior on top of this lives
/// on the ENS page.
struct RPCSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    @State private var newProviderText: String = ""

    var body: some View {
        @Bindable var settings = settings
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
        }
        .navigationTitle("RPC")
        .navigationBarTitleDisplayMode(.inline)
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
}
