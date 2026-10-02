import SwarmKit
import SwiftUI

/// Per-section settings page for the Swarm node: the embedded node's
/// Enable switch, or an external node's endpoint (desktop "explicit
/// external nodes" under Settings → Nodes), app permissions, and live
/// status.
@MainActor
struct SwarmSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(SwarmNode.self) private var swarm
    @Environment(BeeReadiness.self) private var beeReadiness

    @State private var useExternal = false
    @State private var draft = ""
    @State private var probe: String?
    @State private var probing = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable", isOn: enableBinding)
                    .disabled(useExternal)
            } header: {
                Text("Embedded node")
            } footer: {
                Text(useExternal
                     ? "Off while an external node is in use."
                     : "Run the embedded Swarm node on app launch and right now. Disable to free CPU / memory; bzz:// page loads will fail until re-enabled.")
            }

            Section {
                Toggle("Use an external node", isOn: externalBinding)
                if useExternal {
                    TextField("https://bee.example.com or http://192.168.1.20:1633", text: $draft)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(save)
                    HStack {
                        Button("Save") { save() }
                            .disabled(!canSave)
                        Spacer()
                        Button(probing ? "Testing…" : "Test connection") { Task { await test() } }
                            .disabled(probing || parsed == nil)
                    }
                    if let probe {
                        Text(probe).font(.caption).foregroundStyle(probe.hasPrefix("OK") ? .green : .red)
                    }
                }
            } header: {
                Text("External node")
            } footer: {
                Text(externalFooter)
            }

            Section {
                NavigationLink("App permissions") { SwarmManifestSettingsView() }
            } header: {
                Text("Apps")
            } footer: {
                Text("Swarm apps that declare their permissions up front, and whether you let the declaration apply or kept asking each time.")
            }

            Section {
                if settings.usesExternalSwarmEndpoint {
                    LabeledContent("Endpoint", value: settings.swarmExternalEndpointURL?.host() ?? "—")
                    LabeledContent("Node", value: readinessLabel)
                } else {
                    LabeledContent("Status", value: swarm.status.rawValue.capitalized)
                    LabeledContent("Connected peers", value: "\(swarm.peerCount)")
                }
            } header: {
                Text("Live")
            }
        }
        .navigationTitle("Swarm")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            useExternal = settings.usesExternalSwarmEndpoint
            draft = settings.swarmExternalEndpoint
        }
    }

    private var parsed: URL? { try? SwarmGateway.parseExternal(draft).get() }

    private var canSave: Bool {
        guard let parsed else { return false }
        return parsed != settings.swarmExternalEndpointURL
    }

    private var externalFooter: String {
        guard useExternal else {
            return "Point Freedom at a Swarm node outside the app — a bee or ant on your network or a server. Its identity, storage and stamps are then that node's, and the embedded node stays off."
        }
        if draft.trimmingCharacters(in: .whitespaces).isEmpty {
            return "The node's API address. Cleartext http:// is accepted for your local network only."
        }
        switch SwarmGateway.parseExternal(draft) {
        case .success: return settings.usesExternalSwarmEndpoint ? "In use." : "Tap Save to use this node."
        case .failure(let error): return error.message
        }
    }

    private var readinessLabel: String {
        switch beeReadiness.state {
        case .ready: "ready"
        case .startingUp: "starting up"
        case .syncingPostage(let percent, _, _): "syncing \(percent)%"
        case .initializing: "connecting"
        }
    }

    private func save() {
        guard let parsed else { return }
        settings.swarmExternalEndpoint = parsed.absoluteString
        draft = parsed.absoluteString
        probe = nil
    }

    private func test() async {
        guard let parsed else { return }
        probing = true
        defer { probing = false }
        switch await SwarmGateway.probe(parsed) {
        case .success(let line): probe = "OK · \(line)"
        case .failure(let error): probe = "Couldn't reach it: \(error.localizedDescription)"
        }
    }

    private var enableBinding: Binding<Bool> {
        Binding(
            get: { settings.swarmNodeEnabled },
            set: { newValue in
                settings.swarmNodeEnabled = newValue
                if newValue {
                    Task { await SwarmRuntime.enable(swarm: swarm, settings: settings) }
                } else {
                    swarm.stop()
                }
            }
        )
    }

    /// Off clears the endpoint at once (the embedded node comes back if
    /// enabled); on only reveals the field — the endpoint applies on Save.
    private var externalBinding: Binding<Bool> {
        Binding(
            get: { useExternal },
            set: { newValue in
                useExternal = newValue
                if !newValue {
                    settings.swarmExternalEndpoint = ""
                    probe = nil
                }
            }
        )
    }
}
