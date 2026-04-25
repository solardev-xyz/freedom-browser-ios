import Foundation
import Observation
import OSLog
import SwiftData

private let log = Logger(subsystem: "com.browser.Freedom", category: "AutoApproveStore")

/// SwiftData backing for persistence + an in-memory `Set<String>` of
/// composite keys for the bridge's hot-path `matches(...)` check.
/// `eth_sendTransaction` consults this synchronously before parking the
/// approval sheet — must be O(1) and reachable outside a SwiftUI view.
@MainActor
@Observable
final class AutoApproveStore {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var keys: Set<String>

    init(context: ModelContext) {
        self.context = context
        let descriptor = FetchDescriptor<AutoApproveRule>()
        let fetched = (try? context.fetch(descriptor)) ?? []
        self.keys = Set(fetched.map(\.key))
    }

    func grant(_ offer: AutoApproveOffer) {
        let rule = AutoApproveRule(offer: offer)
        guard !keys.contains(rule.key) else { return }
        context.insert(rule)
        keys.insert(rule.key)
        save()
    }

    func revoke(_ rule: AutoApproveRule) {
        let key = rule.key
        context.delete(rule)
        keys.remove(key)
        save()
    }

    func matches(_ offer: AutoApproveOffer) -> Bool {
        keys.contains(AutoApproveRule.makeKey(offer: offer))
    }

    private func save() {
        do {
            try context.save()
        } catch {
            log.error("AutoApproveRule save failed: \(String(describing: error), privacy: .public)")
        }
    }
}
