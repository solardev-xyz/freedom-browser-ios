import SwiftUI

/// Per-category toggles + status + per-site allowlist + filter-list
/// attribution. Edits live-refresh every open tab.
struct AdblockSettingsView: View {
    @Environment(AdblockService.self) private var adblock
    @Environment(SettingsStore.self) private var settings

    @State private var isAddingSite = false
    @State private var newSiteText = ""

    var body: some View {
        Form {
            Section {
                statusRow
            } header: {
                Text("Status")
            }

            Section {
                toggleRow(.ads)
                toggleRow(.privacy)
                toggleRow(.cookies)
                toggleRow(.annoyances)
            } header: {
                Text("Filter lists")
            } footer: {
                Text("Toggles apply live to all open tabs. Already-rendered content keeps its current state until you reload the page.")
            }

            allowlistSection

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
        .alert("Add allowlisted site", isPresented: $isAddingSite) {
            TextField("example.com", text: $newSiteText)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { newSiteText = "" }
            Button("Add") {
                let toAdd = newSiteText
                newSiteText = ""
                adblock.addAllowlist(domain: toAdd)
            }
            .disabled(adblock.normalizedHost(newSiteText) == nil)
        } message: {
            Text("All adblock categories will be bypassed on this domain and its subdomains.")
        }
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

    private func toggleRow(_ category: AdblockService.Category) -> some View {
        // Routes through `setEnabled` so the live refresh fires; binding
        // directly to `settings.adblockXEnabled` would skip it.
        let binding = Binding(
            get: { adblock.isEnabled(category) },
            set: { adblock.setEnabled(category, $0) }
        )
        return Toggle(isOn: binding) {
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

    private var allowlistSection: some View {
        Section {
            ForEach(adblock.allowlistDomains, id: \.self) { domain in
                Text(domain)
            }
            .onDelete { indexSet in
                let domains = adblock.allowlistDomains
                adblock.removeAllowlist(domains: indexSet.map { domains[$0] })
            }
            Button {
                newSiteText = ""
                isAddingSite = true
            } label: {
                Label("Add site…", systemImage: "plus")
            }
        } header: {
            Text("Allowlisted sites")
        } footer: {
            if adblock.allowlistDomains.isEmpty {
                Text("Sites you add here have all adblock categories bypassed. Useful when blocking breaks a page you trust.")
            } else {
                Text("Adblock is bypassed on \(adblock.allowlistDomains.count) site\(adblock.allowlistDomains.count == 1 ? "" : "s") and their subdomains. Swipe to remove.")
            }
        }
    }
}
