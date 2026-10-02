import SwiftUI

/// Settings → About: version, source, what the app is built with, and
/// the open-source licences of everything bundled.
struct AboutView: View {
    private let inventory = LicenseInventory.shared

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Freedom").font(.title2).bold()
                    Text("Version \(Self.version)").foregroundStyle(.secondary)
                    Text("A browser for the decentralised web: Swarm, IPFS, Radicle, onchain apps and verified names, with a wallet.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                if let url = URL(string: inventory?.app.url ?? "https://github.com/solardev-xyz/freedom-browser-ios") {
                    Link(destination: url) {
                        Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
            } footer: {
                if let license = inventory?.app.license {
                    Text("Freedom's own licence: \(license).")
                }
            }

            if let inventory {
                Section("Built with") {
                    ForEach(inventory.components) { component in
                        NavigationLink(value: SettingsPath.license(component.id)) {
                            LabeledContent(component.name, value: component.version)
                        }
                    }
                }
                Section {
                    NavigationLink(value: SettingsPath.licenses) {
                        Label("Open-source licences", systemImage: "doc.text")
                    }
                } footer: {
                    Text("\(inventory.swiftPackages.count) Swift packages, \(inventory.rustCrates.count) Rust crates in FreedomMobile \(inventory.ffiTag), \(inventory.filterLists.count) filter lists. Inventory generated \(inventory.generated).")
                }
            } else {
                Section {
                    Text("The licence inventory is missing from this build.").foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// Every bundled component, searchable, grouped by where it comes from.
struct LicensesView: View {
    private let inventory = LicenseInventory.shared
    @State private var query = ""

    var body: some View {
        List {
            if let inventory {
                section("Components", inventory.components)
                section("Filter lists", inventory.filterLists)
                section("Swift packages", inventory.swiftPackages)
                section("Rust crates (FreedomMobile \(inventory.ffiTag))", inventory.rustCrates)
            }
        }
        .searchable(text: $query, prompt: "Search components")
        .navigationTitle("Licences")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func section(_ title: String, _ entries: [LicenseInventory.Entry]) -> some View {
        let shown = entries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        if !shown.isEmpty {
            Section("\(title) (\(shown.count))") {
                ForEach(shown) { entry in
                    NavigationLink(value: SettingsPath.license(entry.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                            Text("\(entry.version) · \(entry.license)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

/// One component: facts, notice, and the licence texts that apply.
struct LicenseDetailView: View {
    let id: String
    private let inventory = LicenseInventory.shared

    var body: some View {
        List {
            if let inventory, let entry = inventory.entry(id: id) {
                Section {
                    LabeledContent("Version", value: entry.version)
                    LabeledContent("Licence", value: entry.license)
                    if let url = entry.url.flatMap(URL.init(string:)) {
                        Link(destination: url) { Label("Project page", systemImage: "link") }
                    }
                    if let url = entry.sourceURL.flatMap(URL.init(string:)) {
                        Link(destination: url) { Label("List source", systemImage: "list.bullet") }
                    }
                } header: {
                    Text(entry.name)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let copyright = entry.copyright { Text(copyright) }
                        if let note = entry.note { Text(note) }
                    }
                }
                if let notice = entry.notice {
                    Section("Notice") { licenseText(notice) }
                }
                ForEach(Array(inventory.texts(for: entry).enumerated()), id: \.offset) { _, item in
                    Section(item.title) { licenseText(item.text) }
                }
            } else {
                Text("Unknown component.").foregroundStyle(.secondary)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func licenseText(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
    }
}
