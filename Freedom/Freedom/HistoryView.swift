import SwiftUI
import SwiftData

struct HistoryView: View {
    let onSelect: (BrowserURL) -> Void

    @Environment(HistoryStore.self) private var historyStore
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \HistoryEntry.visitedAt, order: .reverse) private var history: [HistoryEntry]

    @State private var isShowingClearConfirm = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(dayGroups, id: \.label) { group in
                    Section(header: Text(group.label)) {
                        ForEach(group.entries) { entry in
                            Button { select(entry) } label: {
                                HistoryRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    historyStore.delete(entry)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if history.isEmpty {
                    ContentUnavailableView {
                        Label("No history", systemImage: "clock")
                    } description: {
                        Text("Pages you visit will appear here.")
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") {
                        isShowingClearConfirm = true
                    }
                    .disabled(history.isEmpty)
                }
            }
            .confirmationDialog(
                "Clear all history?",
                isPresented: $isShowingClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive) {
                    historyStore.clearAll()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func select(_ entry: HistoryEntry) {
        guard let classified = BrowserURL.classify(entry.url) else { return }
        onSelect(classified)
        dismiss()
    }

    private var dayGroups: [DayGroup] {
        var seenLabels: [String] = []
        var byLabel: [String: [HistoryEntry]] = [:]
        for entry in history {
            let label = dayLabel(for: entry.visitedAt)
            if byLabel[label] == nil {
                byLabel[label] = []
                seenLabels.append(label)
            }
            byLabel[label]?.append(entry)
        }
        return seenLabels.map { DayGroup(label: $0, entries: byLabel[$0]!) }
    }
}

private struct DayGroup {
    let label: String
    let entries: [HistoryEntry]
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.displayTitle)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(entry.url.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }
}

private func dayLabel(for date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return "Today" }
    if cal.isDateInYesterday(date) { return "Yesterday" }
    let now = Date()
    if let week = cal.dateInterval(of: .weekOfYear, for: now), week.contains(date) {
        return date.formatted(.dateTime.weekday(.wide))
    }
    return date.formatted(.dateTime.month().day().year())
}
