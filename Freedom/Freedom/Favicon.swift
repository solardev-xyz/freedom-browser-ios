import Foundation
import SwiftData

@Model
final class Favicon {
    @Attribute(.unique) var host: String
    @Attribute(.externalStorage) var imageData: Data
    var fetchedAt: Date

    init(host: String, imageData: Data, fetchedAt: Date = Date()) {
        self.host = host
        self.imageData = imageData
        self.fetchedAt = fetchedAt
    }
}
