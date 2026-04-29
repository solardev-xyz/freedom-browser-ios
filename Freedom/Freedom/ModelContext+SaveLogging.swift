import Foundation
import OSLog
import SwiftData

extension ModelContext {
    /// Best-effort `save()` that swallows the error after logging it.
    /// Used by every SwiftData-backed store on every mutating call —
    /// the alternative is hand-rolled `do { try save() } catch { log }`
    /// that drifted across stores. Caller passes a per-store `Logger`
    /// so the OSLog category stays specific.
    func saveLogging(_ label: String, to logger: Logger) {
        do {
            try save()
        } catch {
            logger.error(
                "\(label) save failed: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
