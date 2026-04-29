import SwiftUI

/// Reads via the store's observable `entries` array so a `record()`
/// from the bridge propagates to a visible list without manual refresh.
@MainActor
struct SwarmPublishHistoryView: View {
    @Environment(SwarmPublishHistoryStore.self) private var store
    @State private var showClearConfirmation = false

    var body: some View {
        let entries = store.entries
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if entries.isEmpty {
                    emptyState
                } else {
                    list(entries)
                }
            }
            .padding(20)
        }
        .navigationTitle("Publish history")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .confirmationDialog(
            "Clear all publish history?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            // Destructive — deleting the record won't unpin the data
            // from Swarm, but the user loses their local pointer to it.
            Button("Clear all", role: .destructive) { store.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the local list. Data already published to Swarm stays on the network.")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nothing published yet")
                .font(.title3).fontWeight(.semibold)
            Text("When dapps use this node to publish to Swarm, the references show up here so you can find them later.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func list(_ entries: [SwarmPublishHistoryRecord]) -> some View {
        VStack(spacing: 12) {
            ForEach(entries) { entry in
                NavigationLink {
                    SwarmPublishHistoryDetailView(entryId: entry.id)
                } label: {
                    HistoryCard(entry: entry)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

@MainActor
private struct HistoryCard: View {
    let entry: SwarmPublishHistoryRecord

    var body: some View {
        HStack {
            SwarmPublishHistoryFormatting.kindIcon(entry.kind)
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name ?? SwarmPublishHistoryFormatting.kindLabel(entry.kind))
                    .font(.callout).fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(SwarmPublishHistoryFormatting.relativeTime(entry.startedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SwarmPublishHistoryStatusBadge(status: entry.status)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
