import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.browser.Freedom", category: "SwarmManifest")

/// Per-origin memory of a manifest consent. Field names and the file
/// layout match desktop's `swarm-manifest-grants.json` (`{version: 1,
/// records: {origin: record}}`).
struct SwarmManifestRecord: Codable, Equatable {
    enum Decision: String, Codable, Equatable {
        /// The manifest owns the projected grants ("Allow all").
        case managed
        /// Normal per-action prompts ("ask each time", or the grants
        /// already existed by the user's own hand).
        case individual
    }

    struct App: Codable, Equatable {
        var name: String
        var description: String
    }

    struct Observed: Codable, Equatable {
        var fingerprint: String
        var rawHash: String
        /// capability → why
        var capabilities: [String: String]
        var checkedAt: Date
    }

    struct Acknowledgement: Codable, Equatable {
        var decision: Decision
        /// `sheet` or `existing-grant`.
        var source: String
        var whyShown: String?
        var decidedAt: Date
    }

    struct Receipt: Codable, Equatable {
        struct Row: Codable, Equatable {
            var capability: String
            var browserLabelVersion: Int
            var whyShown: String
        }
        var decidedAt: Date
        var outcome: Decision
        var originShown: String
        var manifestNameShown: String
        var manifestDescriptionShown: String
        var rows: [Row]
        /// Hash of the bytes whose wording the sheet actually showed.
        var rawHash: String
    }

    var app: App?
    var observed: Observed?
    /// capability → the user's answer for it.
    var acknowledged: [String: Acknowledgement] = [:]
    /// projection → capabilities that turned it on. A projection the
    /// user already had is never listed here, so pruning the manifest
    /// never takes away something the user granted by hand.
    var managed: [String: [String]] = [:]
    /// Projections the user changed by hand after the manifest managed
    /// them — a later diff must not resurrect them.
    var detached: [String: Bool] = [:]
    var receipts: [Receipt] = []
    var revision: Int = 0

    static let maxReceipts = 20

    var acknowledgedCapabilities: [(capability: SwarmManifestCapability, acknowledgement: Acknowledgement)] {
        SwarmManifestCapability.allCases.compactMap { capability in
            acknowledged[capability.rawValue].map { (capability, $0) }
        }
    }
}

/// What the consent sheet shows — desktop's `buildConsentModel`.
struct SwarmManifestConsentModel: Equatable {
    struct Row: Equatable {
        let capability: SwarmManifestCapability
        let why: String
    }

    let origin: String
    let name: String
    let description: String
    let changed: [Row]
    let removed: [SwarmManifestCapability]
    let createsIdentity: Bool
    let preservedIdentity: Bool
    let isUpdate: Bool
}

enum SwarmManifestOutcome: String, Equatable {
    case allow
    case individual
    case deny
}

/// Main-actor authority for bzz-hosted Swarm permission manifests —
/// desktop's `permission-manifests.js`. Discovers an app's manifest,
/// diffs it against what the user already acknowledged, hands the
/// bridge a short-lived consent token, and projects the decision onto
/// the connection / feed-identity / auto-approve state the ordinary
/// prompts read. Persisted decisions live in a JSON file next to the
/// SwiftData store.
@MainActor
@Observable
final class SwarmManifestStore {
    typealias Discover = @MainActor (URL) async -> SwarmManifestDiscovery

    static let fileName = "swarm-manifest-grants.json"
    static let tokenTTL: TimeInterval = 5 * 60
    /// Retry delays after an unresolved discovery, per consecutive
    /// failure (desktop `UNRESOLVED_BACKOFF_MS`).
    static let unresolvedBackoff: [TimeInterval] = [2, 10, 30, 60]

    enum CheckResult: Equatable {
        /// No manifest governs this origin — the ordinary prompts apply.
        case legacy
        /// Manifest seen and everything it declares is acknowledged.
        case ready
        /// Could not refresh an origin that has a manifest record.
        case unresolved(retryAt: Date)
        case consent(token: String, model: SwarmManifestConsentModel)
    }

    struct DecisionResult: Equatable {
        let allowed: Bool
        let mode: SwarmManifestOutcome
    }

    enum DecisionError: Swift.Error, Equatable {
        case expired
        case stale
    }

    private struct File: Codable {
        var version = 1
        var records: [String: SwarmManifestRecord]
    }

    private struct Pending {
        let origin: String
        let manifest: SwarmManifest
        let fingerprint: String
        let rawHash: String
        let baseRevision: Int
        let firstContact: Bool
        let changed: [SwarmManifestCapability]
        var expiresAt: Date
    }

    private struct Operation {
        let projection: SwarmManifestProjection
        let enabled: Bool
    }

    private(set) var records: [String: SwarmManifestRecord] = [:]

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let permissionStore: SwarmPermissionStore
    @ObservationIgnored private let feedStore: SwarmFeedStore
    @ObservationIgnored private let discover: Discover
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var tokens: [String: Pending] = [:]
    @ObservationIgnored private var completedTokens: [String: DecisionResult] = [:]
    @ObservationIgnored private var completedOrder: [String] = []
    @ObservationIgnored private var unresolved: [String: (failures: Int, retryAt: Date)] = [:]
    /// Two tabs of one app checking at once must not each mint a token
    /// off the same revision — checks for an origin run one at a time.
    @ObservationIgnored private let originLock = SwarmFeedWriteLock()

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(fileName)
    }

    init(
        fileURL: URL,
        permissionStore: SwarmPermissionStore,
        feedStore: SwarmFeedStore,
        discover: @escaping Discover,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.permissionStore = permissionStore
        self.feedStore = feedStore
        self.discover = discover
        self.now = now
        self.records = Self.load(from: fileURL)
        // A grant the user changes by hand drops manifest ownership of
        // it, so a later diff cannot re-assert what the user undid.
        permissionStore.onUserMutation = { [weak self] origin, projection in
            self?.detachManaged(origin: origin, projection: projection)
        }
        feedStore.onUserMutation = { [weak self] origin, projection in
            self?.detachManaged(origin: origin, projection: projection)
        }
    }

    // MARK: - Public surface

    func record(for origin: String) -> SwarmManifestRecord? {
        records[origin]
    }

    /// Origins with a manifest record, for the settings page.
    var origins: [String] {
        records.keys.sorted()
    }

    /// Desktop's `checkManifest`. `eager` (a `swarm_requestAccess`)
    /// discovers a manifest for an origin without a record; any other
    /// method only refreshes an origin that already has one.
    func check(origin: OriginIdentity, committedURL: URL?, eager: Bool) async -> CheckResult {
        let key = origin.key
        return (try? await originLock.withLock(topicHex: key) { [self] in
            await performCheck(key: key, committedURL: committedURL, eager: eager)
        }) ?? .legacy
    }

    private func performCheck(key: String, committedURL: URL?, eager: Bool) async -> CheckResult {
        let existing = records[key]
        let firstContact = existing == nil && !permissionStore.isConnected(key)
        if existing == nil, !eager { return .legacy }

        if let backoff = unresolved[key], now() < backoff.retryAt {
            return existing != nil ? .unresolved(retryAt: backoff.retryAt) : .legacy
        }

        let found: SwarmManifestDiscovery
        if let committedURL, committedURL.scheme?.lowercased() == "bzz" {
            found = await discover(committedURL)
        } else {
            found = .unsupported
        }

        if found == .unresolved {
            let failures = (unresolved[key]?.failures ?? 0) + 1
            let delay = Self.unresolvedBackoff[min(failures - 1, Self.unresolvedBackoff.count - 1)]
            let retryAt = now().addingTimeInterval(delay)
            unresolved[key] = (failures, retryAt)
            return existing != nil ? .unresolved(retryAt: retryAt) : .legacy
        }
        unresolved[key] = nil

        // The record we may prune must belong to the page that was
        // checked — origin A's record never falls to origin B's state.
        if let committedURL, OriginIdentity.from(displayURL: committedURL)?.key != key {
            return .legacy
        }
        guard case .found(let manifest, let rawHash) = found else {
            if existing != nil { prune(origin: key) }
            return .legacy
        }

        let nextKeys = manifest.declared
        let acknowledged = existing?.acknowledged ?? [:]
        let removed = SwarmManifestCapability.allCases.filter {
            acknowledged[$0.rawValue] != nil && !nextKeys.contains($0)
        }
        let additions = nextKeys.filter { acknowledged[$0.rawValue] == nil }

        var record = existing ?? SwarmManifestRecord()
        let removalOperations = removeOwners(&record, capabilities: removed)
        for capability in removed { record.acknowledged[capability.rawValue] = nil }
        record.observed = .init(
            fingerprint: manifest.fingerprint, rawHash: rawHash,
            capabilities: Dictionary(uniqueKeysWithValues: manifest.capabilities.map { ($0.key.rawValue, $0.value) }),
            checkedAt: now()
        )
        record.app = .init(name: manifest.name, description: manifest.description)
        // A capability the user already granted piece by piece needs no
        // sheet: acknowledge it silently as individual.
        let satisfied = additions.filter { capability in
            capability.projections.allSatisfy { currentValue(origin: key, projection: $0) }
        }
        for capability in satisfied {
            record.acknowledged[capability.rawValue] = .init(
                decision: .individual, source: "existing-grant", whyShown: nil, decidedAt: now()
            )
        }
        let changed = additions.filter { !satisfied.contains($0) }
        record.revision = existing?.revision ?? 0
        if !removalOperations.isEmpty || !removed.isEmpty || !satisfied.isEmpty {
            record.revision += 1
            runTransaction(origin: key, record: record, operations: removalOperations)
        } else {
            records[key] = record
            save()
        }

        if changed.isEmpty { return .ready }
        let pending = Pending(
            origin: key, manifest: manifest, fingerprint: manifest.fingerprint, rawHash: rawHash,
            baseRevision: record.revision, firstContact: firstContact, changed: changed,
            expiresAt: now().addingTimeInterval(Self.tokenTTL)
        )
        let token: String
        if let outstanding = outstandingToken(matching: pending) {
            // A fresh tab coalesced onto this consent — extend the
            // window so the shared token doesn't expire on the earliest
            // requester's clock.
            token = outstanding
            tokens[token]?.expiresAt = pending.expiresAt
        } else {
            token = Self.randomToken()
            tokens[token] = pending
        }
        let model = SwarmManifestConsentModel(
            origin: key, name: manifest.name, description: manifest.description,
            changed: changed.map { .init(capability: $0, why: manifest.capabilities[$0] ?? "") },
            removed: removed,
            createsIdentity: changed.contains(where: { $0 == .feeds || $0 == .signing })
                && feedStore.feedIdentity(origin: key) == nil,
            preservedIdentity: changed.contains(where: { $0 == .feeds || $0 == .signing })
                && feedStore.feedIdentity(origin: key) != nil,
            isUpdate: existing != nil
        )
        return .consent(token: token, model: model)
    }

    /// Desktop's `decideManifest`. Replays a completed token (two tabs
    /// share one sheet), rejects an expired one and one minted against
    /// a record that has since changed.
    @discardableResult
    func decide(token: String, outcome: SwarmManifestOutcome) throws -> DecisionResult {
        if let done = completedTokens[token] { return done }
        guard let pending = tokens[token], pending.expiresAt >= now() else {
            tokens[token] = nil
            throw DecisionError.expired
        }
        let existing = records[pending.origin]
        guard existing?.observed?.fingerprint == pending.fingerprint,
              (existing?.revision ?? 0) == pending.baseRevision else {
            tokens[token] = nil
            throw DecisionError.stale
        }

        if outcome != .deny {
            var record = existing ?? SwarmManifestRecord()
            var operations: [Operation] = []
            if outcome == .individual {
                // "Connect, but ask each time": the connection is the
                // user's own, never manifest-owned.
                record.detached[SwarmManifestProjection.connection.rawValue] = true
                record.managed[SwarmManifestProjection.connection.rawValue] = nil
                if !permissionStore.isConnected(pending.origin) {
                    operations.append(.init(projection: .connection, enabled: true))
                }
            }
            for capability in pending.changed {
                let why = pending.manifest.capabilities[capability] ?? ""
                record.acknowledged[capability.rawValue] = .init(
                    decision: outcome == .allow ? .managed : .individual,
                    source: "sheet", whyShown: why, decidedAt: now()
                )
                if outcome == .allow {
                    operations += addManaged(&record, origin: pending.origin, capability: capability)
                } else {
                    operations += removeOwners(&record, capabilities: [capability])
                }
            }
            record.receipts.append(.init(
                decidedAt: now(),
                outcome: outcome == .allow ? .managed : .individual,
                originShown: pending.origin,
                manifestNameShown: pending.manifest.name,
                manifestDescriptionShown: pending.manifest.description,
                rows: pending.changed.map {
                    .init(capability: $0.rawValue, browserLabelVersion: 1,
                          whyShown: pending.manifest.capabilities[$0] ?? "")
                },
                rawHash: pending.rawHash
            ))
            record.receipts = Array(record.receipts.suffix(SwarmManifestRecord.maxReceipts))
            record.revision = pending.baseRevision + 1
            runTransaction(origin: pending.origin, record: record, operations: operations)
        } else if pending.firstContact {
            // A rejected first contact leaves no trace of the app.
            runTransaction(origin: pending.origin, record: nil, operations: [])
        }

        let result = DecisionResult(allowed: outcome != .deny, mode: outcome)
        tokens[token] = nil
        completedTokens[token] = result
        completedOrder.append(token)
        if completedOrder.count > 100 {
            completedTokens[completedOrder.removeFirst()] = nil
        }
        return result
    }

    /// Settings "Ask each time": the capability keeps its
    /// acknowledgement but the manifest no longer owns its grants.
    @discardableResult
    func useIndividual(origin: String, capability: SwarmManifestCapability) -> Bool {
        guard var record = records[origin], let existing = record.acknowledged[capability.rawValue] else {
            return false
        }
        record.detached[SwarmManifestProjection.connection.rawValue] = true
        record.managed[SwarmManifestProjection.connection.rawValue] = nil
        let operations = removeOwners(&record, capabilities: [capability])
        record.acknowledged[capability.rawValue] = .init(
            decision: .individual, source: existing.source, whyShown: existing.whyShown, decidedAt: now()
        )
        record.revision += 1
        runTransaction(origin: origin, record: record, operations: operations)
        return true
    }

    /// Forget the app entirely: its record and its connection.
    func disconnect(origin: String) {
        runTransaction(origin: origin, record: nil, operations: [
            .init(projection: .connection, enabled: false),
        ])
    }

    /// The user changed a projected grant by hand — drop manifest
    /// ownership so the next diff can't resurrect it.
    func detachManaged(origin: String, projection: String) {
        if projection == SwarmManifestProjection.connection.rawValue {
            if records[origin] != nil { disconnect(origin: origin) }
            return
        }
        guard var record = records[origin] else { return }
        record.detached[projection] = true
        record.managed[projection] = nil
        record.revision += 1
        runTransaction(origin: origin, record: record, operations: [])
    }

    // MARK: - Projections

    private func currentValue(origin: String, projection: SwarmManifestProjection) -> Bool {
        switch projection {
        case .connection: permissionStore.isConnected(origin)
        case .identity: feedStore.feedIdentity(origin: origin) != nil
        case .messagingGrant: permissionStore.hasMessagingGrant(origin)
        case .autoApprovePublish: permissionStore.isAutoApprovePublish(origin: origin)
        case .autoApproveFeeds: permissionStore.isAutoApproveFeeds(origin: origin)
        case .autoApproveMessaging: permissionStore.isAutoApproveMessaging(origin: origin)
        }
    }

    private func apply(origin: String, projection: SwarmManifestProjection, enabled: Bool) {
        switch projection {
        case .connection:
            if enabled {
                if !permissionStore.isConnected(origin) { permissionStore.grant(origin: origin) }
            } else {
                permissionStore.revoke(origin: origin, source: .manifest)
            }
        case .identity:
            // Identity metadata is never removed — dropping it would
            // orphan feeds already signed with that key.
            if enabled, feedStore.feedIdentity(origin: origin) == nil {
                feedStore.setFeedIdentity(origin: origin, identityMode: .appScoped, source: .manifest)
            }
        case .messagingGrant:
            if enabled {
                permissionStore.grantMessaging(origin: origin, source: .manifest)
            } else {
                permissionStore.revokeMessaging(origin: origin, source: .manifest)
            }
        case .autoApprovePublish:
            permissionStore.setAutoApprovePublish(origin: origin, enabled: enabled, source: .manifest)
        case .autoApproveFeeds:
            permissionStore.setAutoApproveFeeds(origin: origin, enabled: enabled, source: .manifest)
        case .autoApproveMessaging:
            permissionStore.setAutoApproveMessaging(origin: origin, enabled: enabled, source: .manifest)
        }
    }

    /// Withdraw `capabilities` as owners of the projections they turned
    /// on; a projection left without owners is switched off (identity
    /// excepted). Connection goes last: revoking it clears the flags
    /// on its row anyway.
    private func removeOwners(
        _ record: inout SwarmManifestRecord, capabilities: [SwarmManifestCapability]
    ) -> [Operation] {
        var operations: [Operation] = []
        let names = capabilities.map(\.rawValue)
        for (projection, owners) in record.managed {
            let remaining = owners.filter { !names.contains($0) }
            if remaining.isEmpty {
                if let p = SwarmManifestProjection(rawValue: projection), p != .identity {
                    operations.append(.init(projection: p, enabled: false))
                }
                record.managed[projection] = nil
            } else {
                record.managed[projection] = remaining
            }
        }
        return operations.sorted { !($0.projection == .connection) && $1.projection == .connection }
    }

    /// Turn on what `capability` needs, taking ownership only of what
    /// wasn't already on; a projection the user detached stays as is.
    private func addManaged(
        _ record: inout SwarmManifestRecord, origin: String, capability: SwarmManifestCapability
    ) -> [Operation] {
        var operations: [Operation] = []
        for projection in capability.projections {
            if record.detached[projection.rawValue] == true { continue }
            let owners = record.managed[projection.rawValue] ?? []
            if !owners.isEmpty {
                if !owners.contains(capability.rawValue) {
                    record.managed[projection.rawValue] = owners + [capability.rawValue]
                }
                continue
            }
            if !currentValue(origin: origin, projection: projection) {
                record.managed[projection.rawValue] = [capability.rawValue]
                operations.append(.init(projection: projection, enabled: true))
            }
        }
        return operations
    }

    private func prune(origin: String) {
        guard var record = records[origin] else { return }
        let operations = removeOwners(&record, capabilities: SwarmManifestCapability.allCases)
        runTransaction(origin: origin, record: nil, operations: operations)
    }

    /// Apply the projection changes, then persist the record. Stores
    /// write synchronously on the main actor, so unlike desktop no
    /// crash journal is needed between the two.
    private func runTransaction(origin: String, record: SwarmManifestRecord?, operations: [Operation]) {
        for operation in operations {
            apply(origin: origin, projection: operation.projection, enabled: operation.enabled)
        }
        records[origin] = record
        save()
    }

    // MARK: - Tokens

    private func outstandingToken(matching candidate: Pending) -> String? {
        var match: String?
        for (token, pending) in tokens {
            if pending.expiresAt < now() {
                tokens[token] = nil
                continue
            }
            if match == nil, pending.origin == candidate.origin,
               pending.fingerprint == candidate.fingerprint,
               pending.baseRevision == candidate.baseRevision,
               pending.changed == candidate.changed {
                match = token
            }
        }
        return match
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Persistence

    private static func load(from url: URL) -> [String: SwarmManifestRecord] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(File.self, from: data).records
        } catch {
            log.error("manifest grants unreadable, starting empty: \(error)")
            return [:]
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(File(records: records)).write(to: fileURL, options: .atomic)
        } catch {
            log.error("manifest grants save failed: \(error)")
        }
    }
}
