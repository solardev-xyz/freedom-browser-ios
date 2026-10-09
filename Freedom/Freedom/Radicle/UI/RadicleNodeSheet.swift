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
    @Environment(Vault.self) private var vault
    @Environment(RadicleIdentityCoordinator.self) private var radicleIdentity

    @State private var seededRepos: [(rid: String, name: String?)] = []
    @State private var seedInput: String = ""
    @State private var seedFeedback: String?
    /// Bytes on disk per repository, seeded or left over.
    @State private var repoSizes: [String: UInt64] = [:]
    /// Copies in storage that are no longer seeded.
    @State private var leftoverRepos: [String] = []
    @State private var repoToRemove: (rid: String, name: String?)?
    @State private var confirmLeftovers = false
    @State private var removing: Set<String> = []

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
        // Again once the node is up: opened during start-up, the seeded
        // list isn't readable yet.
        .task(id: radicle.status) { await refresh() }
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
                        await RadicleRuntime.start(radicle)
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
                    Text(identityNote)
                        .font(.caption)
                        .foregroundStyle(radicleIdentity.isSwapping ? Color.orange : Color(.tertiaryLabel))
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

    /// Where the identity comes from: the recovery phrase once the vault
    /// has been unlocked since this install derived it, else the node's
    /// own key — with the one-time unlock spelled out.
    private var identityNote: String {
        if radicleIdentity.isSwapping { return "Switching to the identity from your recovery phrase…" }
        if (try? RadicleIdentityStore.shared.load()) != nil { return "From your recovery phrase — the same on every device." }
        switch vault.state {
        case .empty: return "This node's own key. Set up the wallet to derive it from your recovery phrase."
        case .locked, .unlocked: return "Updates to your recovery phrase's identity after you unlock the wallet once."
        }
    }

    private var seedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Seeded repositories")
                    .font(.headline)
                Spacer()
                if !repoSizes.isEmpty {
                    Text("\(RadicleStorage.format(repoSizes.values.reduce(0, +))) on this device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if seededRepos.isEmpty {
                Text("Nothing seeded yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(seededRepos, id: \.rid) { repo in
                    HStack(alignment: .top) {
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
                            if let size = repoSizes[repo.rid] {
                                Text(RadicleStorage.format(size)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(removing.contains(repo.rid) ? "Removing…" : "Remove", role: .destructive) { repoToRemove = repo }
                            .font(.caption)
                            .disabled(removing.contains(repo.rid))
                    }
                }
            }
            if !leftoverRepos.isEmpty {
                HStack {
                    Text("\(leftoverRepos.count) repositor\(leftoverRepos.count == 1 ? "y" : "ies") no longer seeded · \(RadicleStorage.format(leftoverRepos.compactMap { repoSizes[$0] }.reduce(0, +)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", role: .destructive) { confirmLeftovers = true }
                        .font(.caption)
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
        .confirmationDialog(
            "Remove \(repoToRemove?.name.flatMap { $0.isEmpty ? nil : $0 } ?? "this repository") from this device?",
            isPresented: Binding(get: { repoToRemove != nil }, set: { if !$0 { repoToRemove = nil } }),
            titleVisibility: .visible,
            presenting: repoToRemove
        ) { repo in
            Button("Remove", role: .destructive) { remove(repo.rid) }
        } message: { repo in
            Text("This device stops seeding it and deletes its copy here\(repoSizes[repo.rid].map { " (\(RadicleStorage.format($0)))" } ?? ""). Other seeds keep theirs, and you can seed it again later.")
        }
        .confirmationDialog("Delete copies that are no longer seeded?", isPresented: $confirmLeftovers, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { removeLeftovers() }
        } message: {
            Text("They stay on other seeds.")
        }
    }

    /// Stop seeding, stop a fetch in progress, then delete the local copy.
    private func remove(_ rid: String) {
        removing.insert(rid)
        Task {
            if (await seedTracker.status(rid: rid))["state"] as? String == "fetching" {
                await seedTracker.cancelFetch(rid: rid)
            }
            _ = await radicle.unseedRepoJSON(rid: rid)
            _ = await RadicleStorage.removeCopy(rid: rid)
            removing.remove(rid)
            await refresh()
        }
    }

    private func removeLeftovers() {
        let rids = leftoverRepos
        Task {
            for rid in rids { _ = await RadicleStorage.removeCopy(rid: rid) }
            await refresh()
        }
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
        guard radicle.status == .running else {
            // Storage is on disk either way.
            leftoverRepos = RadicleStorage.storedRepos()
            repoSizes = await RadicleStorage.sizes(of: leftoverRepos)
            return
        }
        await radicle.refreshStatus()
        await radicle.refreshIdentity()
        let json = await radicle.listSeededReposJSON()
        if let parsed = (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
            as? [[String: Any]] {
            seededRepos = parsed.map {
                (rid: $0["rid"] as? String ?? "", name: $0["name"] as? String)
            }
        }
        let seeded = Set(seededRepos.map(\.rid))
        let stored = RadicleStorage.storedRepos()
        leftoverRepos = stored.filter { !seeded.contains($0) }
        repoSizes = await RadicleStorage.sizes(of: Array(Set(stored).union(seeded)))
    }
}
