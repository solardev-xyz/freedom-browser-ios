import SwiftUI

/// Per-batch detail view. Pushed when the user taps a `StampCard` in
/// `StampsView`. Surfaces the full batch metadata plus an "Extend"
/// entry point to `StampExtendView`. Reads its batch from
/// `stampService.batch(id:)` so a successful extend (which calls
/// `refreshStamps`) propagates here without re-pushing.
@MainActor
struct StampDetailView: View {
    let batchID: String
    @Environment(StampService.self) private var stampService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let batch = stampService.batch(id: batchID) {
                    metadataCard(batch)
                    extendLink(batch)
                } else {
                    Text("Stamp no longer present.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .navigationTitle("Stamp")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func metadataCard(_ batch: PostageBatch) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StampStatusBadge(usable: batch.usable)
                Spacer()
                if let label = batch.label, !label.isEmpty {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
            }
            metadataRow("Batch ID", value: batch.batchID,
                        font: .system(.caption2, design: .monospaced))
            metadataRow("Size", value: StampFormatting.bytes(batch.effectiveBytes))
            metadataRow("Used", value: "\(batch.usagePercent)%")
            metadataRow("Time remaining", value: StampFormatting.ttl(batch.ttlSeconds))
            metadataRow("Depth", value: "\(batch.depth)")
            metadataRow("Mutable", value: batch.isMutable ? "Yes" : "No")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func extendLink(_ batch: PostageBatch) -> some View {
        NavigationLink {
            StampExtendView(batchID: batch.batchID)
        } label: {
            Label("Extend stamp", systemImage: "arrow.up.circle")
        }
        .buttonStyle(PrimaryActionStyle())
        .disabled(!batch.usable)
    }

    private func metadataRow(
        _ label: String, value: String, font: Font = .callout
    ) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(font)
                .multilineTextAlignment(.trailing)
        }
    }
}
