import SwiftUI

struct TabSwitcher: View {
    @Environment(TabStore.self) private var tabStore
    @Binding var isPresented: Bool

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(tabStore.records, id: \.id) { record in
                        Button {
                            tabStore.activate(record.id)
                            isPresented = false
                        } label: {
                            TabCard(record: record, isActive: record.id == tabStore.activeRecordID)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .task {
                // Capture the active tab's current state so its card in the
                // grid isn't stale/blank — snapshots are otherwise only taken
                // on switch-away or background.
                await tabStore.captureActive()
            }
            .navigationTitle("Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { isPresented = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        tabStore.newTab()
                        isPresented = false
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .overlay {
                if tabStore.records.isEmpty {
                    ContentUnavailableView {
                        Label("No tabs", systemImage: "square.dashed")
                    } description: {
                        Text("Tap + to open a new tab.")
                    }
                }
            }
        }
    }
}

private struct TabCard: View {
    let record: TabRecord
    let isActive: Bool
    @Environment(TabStore.self) private var tabStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                Button { tabStore.close(record.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .font(.title3)
                        .padding(6)
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if isActive {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            Text(displayTitle)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let data = record.lastSnapshot, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 200)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.tertiarySystemBackground))
                .frame(height: 200)
                .overlay {
                    Image(systemName: "globe")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                }
        }
    }

    private var displayTitle: String {
        if let t = record.title, !t.isEmpty { return t }
        if let host = record.url?.host { return host }
        return "New Tab"
    }
}
