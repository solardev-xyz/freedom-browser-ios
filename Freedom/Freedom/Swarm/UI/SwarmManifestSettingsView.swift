import SwiftUI

/// Settings → Swarm → App permissions: every origin with a manifest
/// record, what it declared, and the user's answer per capability —
/// desktop's "Declared by app" section of the per-site permission
/// panel. "Ask each time" withdraws the manifest's ownership of one
/// capability; "Disconnect" forgets the app and its connection.
@MainActor
struct SwarmManifestSettingsView: View {
    @Environment(SwarmManifestStore.self) private var manifestStore

    var body: some View {
        List {
            if manifestStore.origins.isEmpty {
                ContentUnavailableView(
                    "No app manifests",
                    systemImage: "doc.badge.gearshape",
                    description: Text("Swarm apps that declare their permissions appear here once you connect to one.")
                )
            }
            ForEach(manifestStore.origins, id: \.self) { origin in
                if let record = manifestStore.record(for: origin) {
                    section(origin: origin, record: record)
                }
            }
        }
        .navigationTitle("App permissions")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(origin: String, record: SwarmManifestRecord) -> some View {
        Section {
            ForEach(record.acknowledgedCapabilities, id: \.capability) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.capability.label)
                        Text(entry.acknowledgement.decision == .managed
                             ? "Allowed by manifest" : "Individual approvals")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if entry.acknowledgement.decision == .managed {
                        Button("Ask each time") {
                            manifestStore.useIndividual(origin: origin, capability: entry.capability)
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                }
            }
            Button("Disconnect", role: .destructive) {
                manifestStore.disconnect(origin: origin)
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.app?.name ?? origin)
                Text(origin).font(.caption2).textCase(nil)
            }
        } footer: {
            if let receipt = record.receipts.last {
                Text("Last batch decision: \(receipt.outcome == .managed ? "allow all" : "ask each time") · \(receipt.decidedAt.formatted(date: .abbreviated, time: .shortened))")
            }
        }
    }
}
