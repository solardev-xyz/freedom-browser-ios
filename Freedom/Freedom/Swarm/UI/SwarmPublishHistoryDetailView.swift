import SwiftUI
import UIKit

/// Per-row detail. Reads via `entryId` rather than capturing the row
/// at navigation time so a delete-from-here returns to the list with
/// the source store already up-to-date — `entry(id:)` returns nil
/// after the deletion and the view can self-dismiss.
@MainActor
struct SwarmPublishHistoryDetailView: View {
    let entryId: UUID
    @Environment(SwarmPublishHistoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let entry = store.entry(id: entryId) {
                    metadataCard(entry)
                    if entry.status == .failed,
                       let message = entry.errorMessage,
                       !message.isEmpty {
                        errorCard(message)
                    }
                    deleteButton
                } else {
                    Text("Entry no longer present.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .navigationTitle("Publish")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Remove this entry?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                store.delete(id: entryId)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes this entry from your local list. The data stays on Swarm.")
        }
    }

    private func metadataCard(_ entry: SwarmPublishHistoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SwarmPublishHistoryFormatting.kindIcon(entry.kind)
                    .font(.title3)
                Text(SwarmPublishHistoryFormatting.kindLabel(entry.kind))
                    .font(.headline)
                Spacer()
                SwarmPublishHistoryStatusBadge(status: entry.status)
            }
            if let name = entry.name {
                metadataRow("Name", value: name)
            }
            metadataRow("From", value: entry.origin)
            if let bytes = entry.bytesSize {
                metadataRow("Size", value: StampFormatting.bytes(bytes))
            }
            metadataRow("Started", value: entry.startedAt.formatted(date: .abbreviated, time: .shortened))
            if let completedAt = entry.completedAt {
                metadataRow("Finished", value: completedAt.formatted(date: .abbreviated, time: .shortened))
            }
            if let reference = entry.reference {
                CopyableMonoRow(
                    label: SwarmPublishHistoryFormatting.referenceLabel(entry.kind),
                    value: reference
                )
            }
            if let batchId = entry.batchId {
                CopyableMonoRow(label: "Batch", value: batchId)
            }
            if let tagUid = entry.tagUid {
                metadataRow("Tag", value: "\(tagUid)")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Error").font(.caption).foregroundStyle(.secondary)
            Text(message).font(.callout)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            showDeleteConfirmation = true
        } label: {
            Label("Remove from history", systemImage: "trash")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.red)
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout).multilineTextAlignment(.trailing)
        }
    }
}

/// Tap-to-copy row for opaque hex / batch ids — rendered monospaced
/// because that's the only legible form for 64-char references. Mirrors
/// `CopyableAddressRow` in `NodeHomeView` but takes a label since this
/// view shows two of them stacked (reference + batch id).
@MainActor
private struct CopyableMonoRow: View {
    let label: String
    let value: String
    @State private var didCopy: Bool = false

    var body: some View {
        Button(action: copy) {
            HStack(alignment: .top) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(value.shortenedHex())
                    .font(.system(.footnote, design: .monospaced))
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.footnote)
                    .foregroundStyle(didCopy ? Color.green : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func copy() {
        UIPasteboard.general.string = value
        withAnimation { didCopy = true }
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            withAnimation { didCopy = false }
        }
    }
}
