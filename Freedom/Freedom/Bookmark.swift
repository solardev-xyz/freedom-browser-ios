import Foundation
import SwiftData

@Model
final class Bookmark {
    @Attribute(.unique) var id: UUID
    var url: URL
    var title: String?
    var host: String?
    var createdAt: Date
    /// Manual order (desktop "reorder by drag"): ascending, newest
    /// bookmarks placed first. Pre-existing rows migrate in at 0 and
    /// fall back to `createdAt` among themselves until the first move
    /// renumbers everything.
    var sortIndex: Int = 0

    init(id: UUID = UUID(), url: URL, title: String? = nil, createdAt: Date = Date(), sortIndex: Int = 0) {
        self.id = id
        self.url = url
        self.title = title
        self.host = url.host
        self.createdAt = createdAt
        self.sortIndex = sortIndex
    }

    /// The list order everywhere bookmarks are shown.
    static let order: [SortDescriptor<Bookmark>] = [
        SortDescriptor(\.sortIndex), SortDescriptor(\.createdAt, order: .reverse),
    ]

    /// Apply an edit: an empty title clears it; the host follows the URL.
    func update(title: String?, url: URL) {
        self.title = (title?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
        self.url = url
        self.host = url.host
    }

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        return host ?? url.absoluteString
    }
}
