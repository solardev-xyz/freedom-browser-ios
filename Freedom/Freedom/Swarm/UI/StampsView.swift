import BigInt
import SwiftUI

/// Stamps list — the entry point from the node sheet for users who've
/// already finished publish-setup. Empty state pushes straight to the
/// purchase form so a fresh node ready+no-stamps user has one tap to
/// the buy flow.
@MainActor
struct StampsView: View {
    @Environment(StampService.self) private var stampService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if stampService.stamps.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .padding(20)
        }
        .navigationTitle("Storage stamps")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !stampService.stamps.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        StampPurchaseView()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .task { await stampService.refreshStamps() }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("No stamps yet")
                .font(.title3).fontWeight(.semibold)
            Text("A stamp pre-pays the network for storing your data. Buy one to start publishing.")
                .font(.callout)
                .foregroundStyle(.secondary)
            NavigationLink {
                StampPurchaseView()
            } label: {
                Label("Buy your first stamp", systemImage: "plus.circle.fill")
            }
            .buttonStyle(PrimaryActionStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var list: some View {
        VStack(spacing: 12) {
            ForEach(stampService.stamps) { batch in
                NavigationLink {
                    StampDetailView(batchID: batch.batchID)
                } label: {
                    StampCard(batch: batch)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// One row per batch in the stamps list. Mirrors desktop's batch card —
/// status badge, size, usage, TTL, shortened batch id.
@MainActor
private struct StampCard: View {
    let batch: PostageBatch

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StampStatusBadge(usable: batch.usable)
                Spacer()
                Text(batch.batchID.shortenedHex())
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            row(label: "Size", value: StampFormatting.bytes(batch.effectiveBytes))
            row(label: "Used", value: "\(batch.usagePercent)%")
            row(label: "Time remaining", value: StampFormatting.ttl(batch.ttlSeconds))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(batch.usable ? 1.0 : 0.6)
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout)
        }
    }
}
