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

    init(id: UUID = UUID(), url: URL? = nil, title: String? = nil, lastSnapshot: Data? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.lastSnapshot = lastSnapshot
        let now = Date()
        self.createdAt = now
        self.lastActiveAt = now
    }
}
