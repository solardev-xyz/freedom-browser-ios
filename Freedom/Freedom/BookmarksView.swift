import SwiftData
import SwiftUI

/// The bookmark list. Safari's shape: tap opens, swipe deletes or edits,
/// Edit mode reorders by drag handle and turns a tap into the editor.
struct BookmarksView: View {
    let onSelect: (BrowserURL) -> Void

    @Environment(BookmarkStore.self) private var bookmarkStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.editMode) private var editMode
    @Query(sort: Bookmark.order) private var bookmarks: [Bookmark]
    @State private var editing: Bookmark?

    var body: some View {
        NavigationStack {
            List {
                ForEach(bookmarks) { bookmark in
                    Button {
                        if editMode?.wrappedValue.isEditing == true { editing = bookmark } else { select(bookmark) }
                    } label: {
                        URLRow(title: bookmark.displayTitle, url: bookmark.url)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            bookmarkStore.delete(bookmark)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            editing = bookmark
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        Button { editing = bookmark } label: { Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive) { bookmarkStore.delete(bookmark) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                .onMove { source, destination in
                    bookmarkStore.move(fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    for index in offsets { bookmarkStore.delete(bookmarks[index]) }
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
                ToolbarItem(placement: .topBarTrailing) {
                    if !bookmarks.isEmpty { EditButton() }
                }
            }
            .sheet(item: $editing) { bookmark in
                BookmarkEditView(bookmark: bookmark)
            }
        }
    }

    private func select(_ bookmark: Bookmark) {
        guard let classified = BrowserURL.classify(bookmark.url) else { return }
        onSelect(classified)
        dismiss()
    }
}

/// Name and address of one bookmark (desktop's edit modal).
struct BookmarkEditView: View {
    let bookmark: Bookmark
    @Environment(BookmarkStore.self) private var bookmarkStore
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var address: String

    init(bookmark: Bookmark) {
        self.bookmark = bookmark
        _title = State(initialValue: bookmark.title ?? "")
        _address = State(initialValue: bookmark.url.absoluteString)
    }

    private var isValidAddress: Bool { BookmarkStore.url(fromAddress: address) != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Address", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    if !isValidAddress {
                        Text("Enter a name (foo.eth), bzz://<hash>, or https://…").foregroundStyle(.red)
                    } else if title.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Without a title the bookmark shows its host.")
                    }
                }
            }
            .navigationTitle("Edit Bookmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if bookmarkStore.update(bookmark, title: title, address: address) { dismiss() }
                    }
                    .disabled(!isValidAddress)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
