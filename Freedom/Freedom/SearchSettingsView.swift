import SwiftUI

/// Settings → Search: the engine that answers address-bar input which
/// is not a URL, hash or name (desktop "Settings → Search" parity).
struct SearchSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    private var customValid: Bool { SearchEngine.normalizeTemplate(settings.customSearchTemplate) != nil }
    private var customNamed: Bool {
        !settings.customSearchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Search engine", selection: $settings.searchProvider) {
                    ForEach(SearchEngine.allCases) { engine in
                        Text(engine.label).tag(engine.rawValue)
                    }
                    Text("Custom").tag(SearchEngine.customID)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Search engine")
            } footer: {
                Text("Anything typed into the address bar that is not a URL, a hash or a name is searched with this engine.")
            }

            if settings.searchProvider == SearchEngine.customID {
                Section {
                    TextField("Name", text: $settings.customSearchName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    TextField("https://example.com/search?q={searchTerms}", text: $settings.customSearchTemplate)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.caption).monospaced()
                } header: {
                    Text("Custom engine")
                } footer: {
                    if customValid && customNamed {
                        Text("Searches go to \(settings.customSearchName.trimmingCharacters(in: .whitespacesAndNewlines)).")
                    } else {
                        Text("An HTTPS URL with exactly one {searchTerms} (or %s) placeholder and a name. Until both are valid, \(SearchEngine.default.label) is used.")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
    }
}
