import Foundation
import Observation
import SwiftData

/// Read-only access to `SwarmFeedRecord`. Backs `swarm_readFeedEntry`'s
/// `name → owner` lookup and `swarm_listFeeds`. Writers
/// (`swarm_createFeed`, `swarm_updateFeed`) land in WP6.
@MainActor
@Observable
final class SwarmFeedStore {
    @ObservationIgnored private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func lookup(origin: String, name: String) -> SwarmFeedRecord? {
        let descriptor = FetchDescriptor<SwarmFeedRecord>(
            predicate: #Predicate { $0.origin == origin && $0.name == name }
        )
        return try? context.fetch(descriptor).first
    }

    /// Oldest-first — matches the order the calling dapp's
    /// `swarm_createFeed` calls happened.
    func all(forOrigin origin: String) -> [SwarmFeedRecord] {
        let descriptor = FetchDescriptor<SwarmFeedRecord>(
            predicate: #Predicate { $0.origin == origin },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
