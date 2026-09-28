import Foundation
import SwiftData

@Model
final class TabRecord {
    @Attribute(.unique) var id: UUID
    var url: URL?
    var title: String?
    @Attribute(.externalStorage) var lastSnapshot: Data?
    var createdAt: Date
    var lastActiveAt: Date
    /// Private tab: ephemeral web data, no history / favicon / suggestion
    /// traces, no page-facing providers; dropped at the next launch.
    var isPrivate: Bool = false

    init(id: UUID = UUID(), url: URL? = nil, title: String? = nil, lastSnapshot: Data? = nil, isPrivate: Bool = false) {
        self.id = id
        self.url = url
        self.title = title
        self.lastSnapshot = lastSnapshot
        self.isPrivate = isPrivate
        let now = Date()
        self.createdAt = now
        self.lastActiveAt = now
    }
}
