import SwiftUI

/// Per-category toggles + status row + filter-list attribution. Toggles
/// take effect on new tabs; existing tabs keep what they were created
/// with until closed (the "Reload to apply" footer is the user's hint).
struct AdblockSettingsView: View {
    @Environment(AdblockService.self) private var adblock
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                statusRow
            } header: {
                Text("Status")
            }

            Section {
                toggleRow(.ads, binding: $settings.adblockAdsEnabled)
                toggleRow(.privacy, binding: $settings.adblockPrivacyEnabled)
                toggleRow(.cookies, binding: $settings.adblockCookiesEnabled)
                toggleRow(.annoyances, binding: $settings.adblockAnnoyancesEnabled)
            } header: {
                Text("Filter lists")
            } footer: {
                Text("Toggles apply to new tabs. Open a new tab — or close and reopen — to test a different combination.")
            }

            if let manifest = adblock.manifest {
                Section {
                    LabeledContent("Bundled version", value: manifest.version)
                    LabeledContent("Converter", value: manifest.libVersion)
                } header: {
                    Text("About the bundled lists")
                } footer: {
                    Text("Filter data is © the respective list authors and dual-licensed GPLv3+ / CC BY-SA 3.0+. EasyList family — see easylist.to.")
                }
            }
        }
        .navigationTitle("Ad Blocking")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch adblock.status {
        case .idle:
            Label("Not yet compiled", systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
        case .compiling:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Compiling rules…").foregroundStyle(.secondary)
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func toggleRow(_ category: AdblockService.Category, binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(category.displayName)
                if let count = adblock.ruleCount(for: category),
                   let shards = adblock.shardCount(for: category) {
                    Text("\(category.subtitle) · \(count.formatted()) rules across \(shards) shard\(shards == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(category.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
