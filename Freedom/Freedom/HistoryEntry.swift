import Foundation
import SwiftData

@Model
final class HistoryEntry {
    @Attribute(.unique) var id: UUID
    var url: URL
    var title: String?
    var host: String?
    var visitedAt: Date

    init(id: UUID = UUID(), url: URL, title: String? = nil, visitedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.host = url.host
        self.visitedAt = visitedAt
    }

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        return host ?? url.absoluteString
    }
}
