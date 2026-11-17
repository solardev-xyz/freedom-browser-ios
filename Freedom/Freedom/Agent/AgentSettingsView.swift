import SwiftUI

/// Settings → Agent: on/off, model provider, key, model, approvals.
struct AgentSettingsView: View {
    @Environment(AgentService.self) private var agent
    @State private var keyDraft = ""
    @State private var keyError: String?
    @State private var keySaved = false
    @State private var isConfirmingDelete = false

    var body: some View {
        @Bindable var settings = agent.settings
        Form {
            Section {
                Toggle("Freedom Agent", isOn: $settings.isEnabled)
                    .onChange(of: settings.isEnabled) { Task { await agent.enabledChanged() } }
            } footer: {
                Text("An AI agent that reads and operates the page you have open, after your approval. It uses a model provider you choose, with your own API key.")
            }

            if settings.isEnabled {
                Section {
                    Picker("Provider", selection: $settings.provider) {
                        ForEach(AgentSettings.Provider.allCases) { Text($0.displayName).tag($0) }
                    }
                    .onChange(of: settings.provider) { keyDraft = ""; keySaved = false }
                    TextField("Model", text: Binding(get: { settings.model }, set: { settings.model = $0 }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    if settings.provider == .openrouter {
                        Toggle("Require zero data retention", isOn: $settings.openrouterZeroRetention)
                            .onChange(of: settings.openrouterZeroRetention) { agent.zeroRetentionChanged() }
                    }
                } header: {
                    Text("Model")
                } footer: {
                    if settings.provider == .openrouter {
                        Text("OpenRouter passes requests to an inference provider. With zero data retention it only picks providers that keep nothing; that's their policy, not encryption, and fewer models are available.")
                    }
                }

                Section {
                    if agent.hasKey && keyDraft.isEmpty {
                        LabeledContent("API key", value: keySaved ? "Saved" : "Stored in the Keychain")
                        Button("Remove key", role: .destructive) { saveKey("") }
                    }
                    SecureField(agent.hasKey ? "Replace the key" : "Paste your \(settings.provider.displayName) API key", text: $keyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { saveKey(keyDraft) }
                    if !keyDraft.isEmpty {
                        Button("Save key") { saveKey(keyDraft) }
                    }
                    Link("Get a key from \(settings.provider.displayName)", destination: settings.provider.keyURL)
                    if let keyError {
                        Text(keyError).foregroundStyle(.red).font(.footnote)
                    }
                } header: {
                    Text("API key")
                } footer: {
                    Text("Kept in this iPhone's Keychain. Requests go straight from your iPhone to \(settings.provider.displayName).")
                }

                Section {
                    Picker("Website actions", selection: $settings.approvalMode) {
                        ForEach(AgentSettings.ApprovalMode.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: settings.approvalMode) { agent.approvalModeChanged() }
                } header: {
                    Text("Approvals")
                } footer: {
                    Text(approvalFooter(settings.approvalMode))
                }

                Section {
                    Button("Delete all chats", role: .destructive) { isConfirmingDelete = true }
                        .confirmationDialog("Delete all agent chats?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                            Button("Delete all chats", role: .destructive) { Task { await agent.deleteAllChats() } }
                        } message: {
                            Text("Their history is removed from this iPhone. Your key and settings stay.")
                        }
                } footer: {
                    Text("Chats are stored on this iPhone only.")
                }

                if settings.hasConsented {
                    Section {
                        Button("Withdraw consent for \(settings.provider.displayName)", role: .destructive) {
                            settings.consentedProviders.remove(settings.provider.rawValue)
                        }
                    } footer: {
                        Text("The agent then asks again before it sends anything to \(settings.provider.displayName).")
                    }
                }
            }
        }
        .navigationTitle("Agent")
    }

    private func approvalFooter(_ mode: AgentSettings.ApprovalMode) -> String {
        switch mode {
        case .everyInteraction:
            "Every click, keystroke and form change on a website waits for you."
        case .sensitiveActions:
            "Reading and moving around run on their own. Anything that submits, sends, buys, posts, deletes or changes an account waits for you; the model judges which is which, and asks when unsure."
        case .allowWebsiteInteractions:
            "Website clicks, typing and form changes run without asking. Use this only on sites you trust."
        }
    }

    private func saveKey(_ key: String) {
        do {
            try agent.setKey(key, for: agent.settings.provider)
            keyDraft = ""
            keyError = nil
            keySaved = !key.isEmpty
        } catch {
            keyError = "The key couldn't be saved: \(error.localizedDescription)"
        }
    }
}

/// First run inside the agent sheet: turn it on, agree to what is sent where
/// (App Store guideline 5.1.2(i)), add a key.
struct AgentSetupView: View {
    @Environment(AgentService.self) private var agent
    @State private var keyDraft = ""
    @State private var keyError: String?

    var body: some View {
        @Bindable var settings = agent.settings
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Freedom Agent", systemImage: "sparkles").font(.title3.bold())
                    Text("Ask about the page you have open, or let the agent work on it: search, fill in forms, find things. It asks before anything that submits, sends or buys.")
                        .font(.subheadline)
                }
                .padding(.vertical, 4)
            }

            Section("Model provider") {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(AgentSettings.Provider.allCases) { Text($0.displayName).tag($0) }
                }
                if !agent.hasKey {
                    SecureField("Paste your \(settings.provider.displayName) API key", text: $keyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Link("Get a key from \(settings.provider.displayName)", destination: settings.provider.keyURL)
                } else {
                    LabeledContent("API key", value: "Stored in the Keychain")
                }
                if let keyError {
                    Text(keyError).foregroundStyle(.red).font(.footnote)
                }
            }

            Section {
                Text(consentText(settings.provider.displayName))
                    .font(.footnote)
                Button {
                    agree()
                } label: {
                    Text(settings.isEnabled ? "Agree and continue" : "Agree and turn on")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!agent.hasKey && keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("What is sent where")
            }
        }
    }

    private func consentText(_ provider: String) -> String {
        "To answer and act, the agent sends your messages and what it reads on the page you have open (its address, text, and the names of buttons, links and form fields) to \(provider), whose terms and privacy policy apply. It sends nothing until you write to it, and nothing from private tabs. Anything you give the agent, passwords included, goes to \(provider) too, so don't ask it to log in for you."
    }

    private func agree() {
        let settings = agent.settings
        if !keyDraft.isEmpty {
            do {
                try agent.setKey(keyDraft, for: settings.provider)
                keyDraft = ""
            } catch {
                keyError = "The key couldn't be saved: \(error.localizedDescription)"
                return
            }
        }
        settings.consentedProviders.insert(settings.provider.rawValue)
        if !settings.isEnabled {
            settings.isEnabled = true
            Task { await agent.enabledChanged() }
        }
    }
}
