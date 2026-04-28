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
                StampCard(batch: batch)
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
                statusBadge
                Spacer()
                Text(batch.batchID.shortenedHex())
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            row(label: "Size", value: formatBytes(batch.effectiveBytes))
            row(label: "Used", value: "\(batch.usagePercent)%")
            row(label: "Time remaining", value: formatTTL(batch.ttlSeconds))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(batch.usable ? 1.0 : 0.6)
    }

    private var statusBadge: some View {
        Text(batch.usable ? "Usable" : "Not usable")
            .font(.caption2).fontWeight(.semibold)
            .foregroundStyle(batch.usable ? Color.green : Color.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                (batch.usable ? Color.green : Color.orange)
                    .opacity(0.15)
            )
            .clipShape(Capsule())
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout)
        }
    }

    /// Bee uses 1000-base units (consistent with bee-js). 1 GB = 1e9.
    private func formatBytes(_ bytes: Int) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return "\(bytes) B"
    }

    private func formatTTL(_ seconds: Int) -> String {
        if seconds <= 0 { return "—" }
        let days = seconds / 86_400
        if days > 0 { return "\(days) day\(days == 1 ? "" : "s")" }
        let hours = seconds / 3600
        if hours > 0 { return "\(hours) hour\(hours == 1 ? "" : "s")" }
        let mins = max(1, seconds / 60)
        return "\(mins) minute\(mins == 1 ? "" : "s")"
    }
}
