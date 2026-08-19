import RadicleKit
import SwiftUI

/// Modal sheet for the embedded Radicle node — sibling of `NodeSheet`
/// (Swarm) / `IpfsNodeSheet` / `MyotisNodeSheet`. Identity + peers +
/// seeded repos, plus a seed-by-RID field so replication can be
/// exercised without a dApp page.
@MainActor
struct RadicleNodeSheet: View {
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            RadicleNodeHomeView()
                .navigationTitle("Radicle")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { isPresented = false }
                    }
                }
        }
    }
}

@MainActor
struct RadicleNodeHomeView: View {
    @Environment(RadicleNode.self) private var radicle
    @Environment(RadicleSeedTracker.self) private var seedTracker
    @Environment(SettingsStore.self) private var settings

    @State private var seededRepos: [(rid: String, name: String?)] = []
    @State private var seedInput: String = ""
    @State private var seedFeedback: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                enableCard
                if settings.radicleNodeEnabled {
                    statusCard
                    identityCard
                    seedCard
                }
            }
            .padding(20)
        }
        .task { await refresh() }
    }

    private var enableCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Enable")
                    .font(.headline)
                Text("Collaborate on Radicle repositories peer-to-peer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Enable", isOn: enableBinding)
                .labelsHidden()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// The toggle only gates the NEXT app launch's auto-start; flipping
    /// it live also starts/stops the node so the effect is immediate.
    private var enableBinding: Binding<Bool> {
        Binding(
            get: { settings.radicleNodeEnabled },
            set: { enabled in
                settings.radicleNodeEnabled = enabled
                Task {
                    if enabled {
                        await radicle.start(alias: "freedom-ios")
                        await radicle.connectSeeds()
                        await refresh()
                    } else {
                        await radicle.shutdown()
                    }
                }
            }
        )
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Node")
                    .font(.headline)
                Spacer()
                Text(radicle.status == .running
                     ? "Online · \(radicle.connectedPeers) peer\(radicle.connectedPeers == 1 ? "" : "s")"
                     : radicle.status.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = radicle.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Identity")
                .font(.headline)
            if let identity = radicle.identity {
                VStack(alignment: .leading, spacing: 4) {
                    Text(identity.alias)
                        .font(.subheadline)
                    Text(identity.did)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            } else {
                Text("Not started")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var seedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Seeded repositories")
                .font(.headline)
            if seededRepos.isEmpty {
                Text("Nothing seeded yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(seededRepos, id: \.rid) { repo in
                    VStack(alignment: .leading, spacing: 2) {
                        if let name = repo.name, !name.isEmpty {
                            Text(name).font(.subheadline)
                        }
                        Text(repo.rid)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("rad:z…", text: $seedInput)
                    .font(.caption.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Seed") { seedTyped() }
                    .buttonStyle(.borderedProminent)
                    .disabled(radicle.status != .running || seedInput.isEmpty)
            }
            if let seedFeedback {
                Text(seedFeedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func seedTyped() {
        guard let rid = RadicleBridge.validateAndNormalizeRid(seedInput) else {
            seedFeedback = "Not a valid repository ID."
            return
        }
        let tracker = seedTracker
        seedFeedback = "Fetching…"
        Task {
            _ = await tracker.startFetch(rid: rid)
            // Poll the snapshot until the fetch settles — the sheet has
            // no event relay of its own and this is a diagnostics
            // surface, not a dApp.
            while true {
                try? await Task.sleep(for: .seconds(1))
                let status = await tracker.status(rid: rid)
                let state = status["state"] as? String ?? "?"
                if state != "fetching" {
                    seedFeedback = state == "fetched"
                        ? "Replicated ✓" : "Fetch \(state): \(status["lastError"] as? String ?? "")"
                    break
                }
            }
            await refresh()
        }
    }

    private func refresh() async {
        guard radicle.status == .running else { return }
        await radicle.refreshStatus()
        await radicle.refreshIdentity()
        let json = await radicle.listSeededReposJSON()
        if let parsed = (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
            as? [[String: Any]] {
            seededRepos = parsed.map {
                (rid: $0["rid"] as? String ?? "", name: $0["name"] as? String)
            }
        }
    }
}
