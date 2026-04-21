import SwiftUI
import SwiftData

struct HistoryView: View {
    let onSelect: (BrowserURL) -> Void

    @Environment(HistoryStore.self) private var historyStore
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \HistoryEntry.visitedAt, order: .reverse) private var history: [HistoryEntry]

    @State private var isShowingClearConfirm = false
    @State private var searchText = ""

    var body: some View {
        let filtered = filteredHistory
        let groups = groupByDay(filtered)
        NavigationStack {
            List {
                ForEach(groups, id: \.label) { group in
                    Section(header: Text(group.label)) {
                        ForEach(group.entries) { entry in
                            Button { select(entry) } label: {
                                URLRow(title: entry.displayTitle, urlString: entry.url.absoluteString)
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
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
            .overlay {
                if filtered.isEmpty {
                    if searchText.isEmpty {
                        ContentUnavailableView {
                            Label("No history", systemImage: "clock")
                        } description: {
                            Text("Pages you visit will appear here.")
                        }
                    } else {
                        ContentUnavailableView.search(text: searchText)
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

    private var filteredHistory: [HistoryEntry] {
        guard !searchText.isEmpty else { return history }
        let lower = searchText.lowercased()
        return history.filter {
            $0.url.absoluteString.lowercased().contains(lower)
            || ($0.title?.lowercased().contains(lower) ?? false)
        }
    }

    private func groupByDay(_ entries: [HistoryEntry]) -> [DayGroup] {
        var seenLabels: [String] = []
        var byLabel: [String: [HistoryEntry]] = [:]
        for entry in entries {
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
