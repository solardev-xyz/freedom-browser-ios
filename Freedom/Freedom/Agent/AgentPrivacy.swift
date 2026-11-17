import Foundation
import OSLog
import SwiftUI

private let log = Logger(subsystem: "com.browser.Freedom", category: "AgentEngine")

/// Where one kind of model request of a chat went (desktop's privacy ledger
/// route): one per provider, model, destination, role, claim and retention.
struct AgentPrivacyRoute: Codable, Equatable {
    enum Role: String, Codable {
        /// The agent itself: answers and tool calls.
        case agent
        /// The interaction classifier deciding whether to ask ("sensitive actions").
        case permission
    }

    var providerId: String
    var providerName: String
    var modelId: String
    /// Scheme, host and port the request went to; empty when unknown.
    var origin: String
    var role: Role
    /// The provider's own label: "routing" (OpenRouter), "standard" (a model lab's API), or "unknown".
    var claim: String
    /// OpenRouter: whether zero-retention routes were required ("required", "not-required"); "unknown" elsewhere.
    var retention: String
    var requests: Int

    func sameRoute(as other: AgentPrivacyRoute) -> Bool {
        providerId == other.providerId && modelId == other.modelId && origin == other.origin
            && role == other.role && claim == other.claim && retention == other.retention
    }

    init?(_ raw: [String: Any]) {
        guard let providerId = raw["providerId"] as? String, let modelId = raw["modelId"] as? String else { return nil }
        self.providerId = String(providerId.prefix(240))
        providerName = String((raw["providerName"] as? String ?? providerId).prefix(240))
        self.modelId = String(modelId.prefix(240))
        origin = String((raw["origin"] as? String ?? "").prefix(300))
        role = (raw["role"] as? String).flatMap(Role.init) ?? .agent
        claim = raw["claim"] as? String ?? "unknown"
        retention = raw["retention"] as? String ?? "unknown"
        requests = 0
    }
}

/// One chat's record of where its model requests went.
struct AgentPrivacyRecord: Codable, Equatable {
    /// The chat existed before this record started: earlier requests aren't listed.
    var earlierUnknown: Bool
    /// Requests past the route limit, counted but not described.
    var omittedRequests = 0
    var routes: [AgentPrivacyRoute] = []
}

/// The privacy records of all chats, in Application Support/Agent/privacy.json
/// next to the chat database; written on every request (they're small).
@MainActor
@Observable
final class AgentPrivacyLedger {
    static let maxRoutes = 32

    private(set) var records: [Int: AgentPrivacyRecord] = [:]
    private let file: URL

    init(directory: URL = AgentDatabase.directory) {
        file = directory.appending(path: "privacy.json")
        if let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode([String: AgentPrivacyRecord].self, from: data) {
            records = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in Int(key).map { ($0, value) } })
        }
    }

    /// A new chat: its record is complete from the start.
    func started(chat: Int) {
        records[chat] = AgentPrivacyRecord(earlierUnknown: false)
        save()
    }

    func record(chat: Int, route: AgentPrivacyRoute) {
        var record = records[chat] ?? AgentPrivacyRecord(earlierUnknown: true)
        if let index = record.routes.firstIndex(where: { $0.sameRoute(as: route) }) {
            record.routes[index].requests += 1
        } else if record.routes.count < Self.maxRoutes {
            var added = route
            added.requests = 1
            record.routes.append(added)
        } else {
            record.omittedRequests += 1
        }
        records[chat] = record
        save()
    }

    func forget(chat: Int) {
        guard records.removeValue(forKey: chat) != nil else { return }
        save()
    }

    func forgetAll() {
        records = [:]
        try? FileManager.default.removeItem(at: file)
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: records.map { (String($0.key), $0.value) })
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            log.error("[privacy] couldn't save the record: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Sheet

/// "Conversation privacy" for one chat (desktop's agent-privacy.js panel,
/// without its hardware and encryption checks, which iOS doesn't do).
struct AgentPrivacyView: View {
    let record: AgentPrivacyRecord?
    let zeroRetention: Bool

    private struct Group: Identifiable {
        let id: String
        let routes: [AgentPrivacyRoute]
        var first: AgentPrivacyRoute { routes[0] }
        var total: Int { routes.reduce(0) { $0 + $1.requests } }
        func requests(_ role: AgentPrivacyRoute.Role) -> Int { routes.filter { $0.role == role }.reduce(0) { $0 + $1.requests } }
    }

    private var groups: [Group] {
        var order: [String] = []
        var grouped: [String: [AgentPrivacyRoute]] = [:]
        for route in record?.routes ?? [] {
            let key = [route.providerId, route.modelId, route.origin].joined(separator: "\u{1F}")
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(route)
        }
        return order.map { Group(id: $0, routes: grouped[$0] ?? []) }
    }

    var body: some View {
        List {
            Section {
                Text(status).font(.headline)
                if record?.earlierUnknown == true || (record?.omittedRequests ?? 0) > 0 {
                    Label("Some earlier or additional requests have no recorded privacy details.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Text("End-to-end encryption is off. The provider may be able to read your messages.")
                    .font(.footnote)
                if groups.contains(where: { $0.first.origin.hasPrefix("http:") }) {
                    Label("Some requests used an unencrypted network connection.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            ForEach(groups) { group in
                Section {
                    routeDetails(group)
                } header: {
                    Text(group.first.modelId.isEmpty ? "Unknown model" : group.first.modelId)
                }
            }
            Section {
                Text("Chat model requests, including the checks that decide whether to ask you before an action. Pages the agent opens, Swarm and wallet requests go to their own services and aren't listed here. Chats and attached files are stored on this iPhone.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("What this covers")
            }
        }
        .navigationTitle("Conversation privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var status: String {
        guard let record, !record.routes.isEmpty else { return "No model requests yet" }
        if record.earlierUnknown || record.omittedRequests > 0 { return "Incomplete privacy history" }
        return "Provider privacy claims"
    }

    @ViewBuilder private func routeDetails(_ group: Group) -> some View {
        let route = group.first
        Text("\(route.providerName) · \(group.total) request\(group.total == 1 ? "" : "s")")
        if route.providerId == "openrouter" {
            let required = group.routes.filter { $0.retention == "required" }.reduce(0) { $0 + $1.requests }
            Text("\(required) of \(group.total) requests required zero-retention routes.")
                .font(.footnote)
            Text(zeroRetention
                 ? "New requests require zero retention. Change this in Agent settings."
                 : "New requests don't require zero retention. Change this in Agent settings.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Text("Responses are not independently verified.").font(.footnote)
        DisclosureGroup("Technical details") {
            Text(route.origin.isEmpty ? "Destination not recorded" : route.origin)
                .font(.footnote.monospaced()).textSelection(.enabled)
            Text(route.origin.hasPrefix("https:")
                 ? "HTTPS encrypts traffic to the service. It is not end-to-end encryption to the model."
                 : "This endpoint does not use HTTPS.")
                .font(.footnote)
            if let claim = claimText(route) {
                Text(claim).font(.footnote)
            }
            if route.providerId == "openrouter" {
                Text("Zero retention is an endpoint policy enforced through routing, not a cryptographic guarantee. OpenRouter account-level prompt logging is controlled separately in your OpenRouter account.")
                    .font(.footnote)
            }
            let agentRequests = group.requests(.agent)
            if agentRequests > 0 {
                Text("Agent · \(agentRequests) request attempt\(agentRequests == 1 ? "" : "s")").font(.footnote)
            }
            let checks = group.requests(.permission)
            if checks > 0 {
                Text("Permission checks · \(checks) request attempt\(checks == 1 ? "" : "s")").font(.footnote)
            }
        }
        .font(.footnote)
    }

    private func claimText(_ route: AgentPrivacyRoute) -> String? {
        switch route.claim {
        case "routing": "Requests go through OpenRouter to an inference provider."
        case "standard": "Requests go to \(route.providerName) under its API data policy."
        default: "Privacy relies on the provider's policy. Freedom doesn't verify it."
        }
    }
}
