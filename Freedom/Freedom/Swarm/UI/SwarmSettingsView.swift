import SwarmKit
import SwiftUI

/// Per-section settings page for the embedded Swarm (bee) node.
/// Reachable from the top-level `SettingsView` hub. Mirrors the IPFS
/// settings page's shape, scoped today to a single Enable toggle —
/// other Swarm-specific controls stay in the Swarm node sheet for now
/// since they're tied to the publish-setup flow.
@MainActor
struct SwarmSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(SwarmNode.self) private var swarm

    @State private var cacheStatus: SwarmCacheStatus?
    @State private var cacheMessage: String?
    @State private var isClearingCache = false
    @State private var confirmClearCache = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Toggle("Enable", isOn: enableBinding)
            } header: {
                Text("Node")
            } footer: {
                Text("Run the embedded Swarm (bee) node on app launch and right now. Disable to free CPU / memory; bzz:// page loads will fail until re-enabled.")
            }

            Section {
                Toggle("Pay peers for faster Swarm", isOn: Binding(
                    get: { settings.swarmSwapEnabled },
                    set: { newValue in
                        settings.swarmSwapEnabled = newValue
                        swarm.setSwapEnabled(newValue)
                    }
                ))
            } header: {
                Text("Bandwidth")
            } footer: {
                Text("Your node pays other nodes small amounts of xBZZ from its chequebook for uploads and for downloads faster than the free tier — up to about 0.75 xBZZ per GB. Off keeps browsing on the free tier (around 5–6 Mbit/s), and large uploads can stall.")
            }

            Section {
                Picker("Swarm cache size", selection: Binding(
                    get: { UInt64(settings.swarmCacheCapacityBytes) },
                    set: { bytes in
                        settings.swarmCacheCapacityBytes = Int(bytes)
                        Task {
                            let error = await swarm.setCacheCapacity(bytes)
                            cacheMessage = error == nil ? "Swarm cache set to \(SwarmCache.label(bytes))." : nil
                            cacheStatus = await swarm.cacheStatus()
                        }
                    }
                )) {
                    ForEach(SwarmCache.sizes, id: \.self) { Text(SwarmCache.label($0)).tag($0) }
                }
                LabeledContent("In use", value: cacheStatus.map { $0.diskEnabled ? SwarmCache.summary($0) : "Unavailable" } ?? "Unknown")
                if cacheStatus?.diskEnabled == true {
                    Button(isClearingCache ? "Clearing…" : "Clear cache", role: .destructive) { confirmClearCache = true }
                        .disabled(isClearingCache)
                }
                if let cacheMessage {
                    Text(cacheMessage).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Cache")
            } footer: {
                Text("How much space the Swarm node keeps for pages and files you've opened, so they load faster next time. Pinned and published content doesn't count towards it.")
            }
            .confirmationDialog("Clear the Swarm cache?", isPresented: $confirmClearCache, titleVisibility: .visible) {
                Button("Clear cache", role: .destructive) { clearCache() }
            } message: {
                Text("Swarm pages you've opened will load from the network again. Pinned and published content is kept.")
            }

            Section {
                NavigationLink("App permissions") { SwarmManifestSettingsView() }
            } header: {
                Text("Apps")
            } footer: {
                Text("Swarm apps that declare their permissions up front, and whether you let the declaration apply or kept asking each time.")
            }

            Section {
                LabeledContent("Status", value: swarm.status.rawValue.capitalized)
                LabeledContent("Connected peers", value: "\(swarm.peerCount)")
            } header: {
                Text("Live")
            }
        }
        .navigationTitle("Swarm")
        .navigationBarTitleDisplayMode(.inline)
        // The usage line follows the node while the page is open (ant
        // reads counters only; cheap to poll).
        .task(id: swarm.status) {
            while !Task.isCancelled {
                cacheStatus = await swarm.cacheStatus()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func clearCache() {
        isClearingCache = true
        cacheMessage = nil
        Task {
            do {
                let result = try await swarm.clearCache()
                cacheMessage = "Freed \(SwarmCache.format(result.freedBytes))."
                cacheStatus = result.status
            } catch {
                cacheMessage = "The Swarm cache wasn't cleared. \(error.localizedDescription)"
            }
            isClearingCache = false
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
}
