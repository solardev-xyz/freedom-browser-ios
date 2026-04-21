import SwiftData
import SwiftUI

struct BookmarksView: View {
    let onSelect: (BrowserURL) -> Void

    @Environment(BookmarkStore.self) private var bookmarkStore
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Bookmark.createdAt, order: .reverse) private var bookmarks: [Bookmark]

    var body: some View {
        NavigationStack {
            List {
                ForEach(bookmarks) { bookmark in
                    Button { select(bookmark) } label: {
                        URLRow(title: bookmark.displayTitle, urlString: bookmark.url.absoluteString)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            bookmarkStore.delete(bookmark)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .overlay {
                if bookmarks.isEmpty {
                    ContentUnavailableView {
                        Label("No bookmarks", systemImage: "bookmark")
                    } description: {
                        Text("Pages you bookmark will appear here.")
                    }
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func select(_ bookmark: Bookmark) {
        guard let classified = BrowserURL.classify(bookmark.url) else { return }
        onSelect(classified)
        dismiss()
    }
}

