import SwiftUI

/// Per-category toggles + status + per-site allowlist + filter-list
/// attribution. Edits live-refresh every open tab.
struct AdblockSettingsView: View {
    @Environment(AdblockService.self) private var adblock
    @Environment(AdblockUpdateService.self) private var updates
    @Environment(SettingsStore.self) private var settings

    @State private var isAddingSite = false
    @State private var newSiteText = ""

    private var scriptletSubtitle: String {
        guard let scriptlets = adblock.scriptlets else { return "uBlock Origin scriptlets" }
        return "uBlock Origin scriptlets · \(scriptlets.ruleCount.formatted()) rules"
    }

    private var versionLabel: String {
        if case .updated(let feedVersion, _) = adblock.listSource {
            return "List version (update \(feedVersion))"
        }
        return "Bundled version"
    }

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

            Section {
                @Bindable var settings = settings
                Toggle(isOn: $settings.adblockScriptletsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Run scriptlets")
                        Text(scriptletSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Small scripts from uBlock Origin that run before a page's own code to remove in-page ads and anti-adblock walls, for example on YouTube. They follow the list switches above. Takes effect on the next page load.")
            }

            allowlistSection

            if let manifest = adblock.manifest {
                Section {
                    LabeledContent(versionLabel, value: manifest.version)
                    LabeledContent("Converter", value: manifest.libVersion)
                    if AdblockUpdateFeed.isTrustAnchorConfigured {
                        @Bindable var settings = settings
                        Toggle("Keep lists up to date", isOn: $settings.adblockAutoUpdateEnabled)
                        updateCheckRow
                    }
                } header: {
                    Text("About the lists")
                } footer: {
                    Text("Filter data is © the respective list authors. EasyList family: dual-licensed GPLv3+ / CC BY-SA 3.0+, see easylist.to. uBlock filters and scriptlets: © Raymond Hill and contributors, GPLv3. Scriptlets run in the page before its own scripts to defuse in-page ads and anti-adblock walls.")
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

    /// When the Swarm feed was last checked and how it went, plus a manual
    /// check — the only place a broken feed shows up for the user.
    private var updateCheckRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Last check")
                if let result = updates.lastResult {
                    Text("\(result.date.formatted(.relative(presentation: .named))) · \(Self.summary(result.outcome))")
                        .font(.caption)
                        .foregroundStyle(Self.isProblem(result.outcome) ? Color.orange : Color.secondary)
                } else {
                    Text("Not checked yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if updates.isChecking {
                ProgressView().controlSize(.small)
            } else {
                Button("Check now") {
                    Task { await updates.runOnce() }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    static func summary(_ outcome: AdblockUpdateService.Outcome) -> String {
        switch outcome {
        case .applied(let version): "Updated to version \(version)."
        case .notNewer(let version): "Up to date (version \(version))."
        case .disabled: "Updates are off."
        case .feedUnavailable(let reason): "Couldn't reach the update feed. \(reason)"
        case .failed(let reason): "Update failed. \(reason)"
        }
    }

    static func isProblem(_ outcome: AdblockUpdateService.Outcome) -> Bool {
        switch outcome {
        case .feedUnavailable, .failed: true
        case .applied, .notNewer, .disabled: false
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
                Text("Sites you add here have all adblock categories bypassed. Useful when blocking breaks a page you trust. You can also turn it off from the site icon in the address bar.")
            } else {
                Text("Adblock is bypassed on \(adblock.allowlistDomains.count) site\(adblock.allowlistDomains.count == 1 ? "" : "s") and their subdomains. Swipe to remove.")
            }
        }
    }
}
