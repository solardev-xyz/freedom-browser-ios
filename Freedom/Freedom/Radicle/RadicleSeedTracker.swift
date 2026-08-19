import Foundation
import Observation
import RadicleKit

/// Honest replication tracking for `radicle_seed` / `radicle_sync` /
/// `radicle_getSeedStatus` — the iOS mirror of desktop's seed-status.js.
///
/// Policy and replication are deliberately separate: `seed` resolves
/// immediately after the fetch is *started*, and the fetch's phase
/// events stream through `seedStatus` provider events. One tracker per
/// app session, shared across tabs, so a reload can restore the latest
/// snapshot with `radicle_getSeedStatus`.
@MainActor
@Observable
final class RadicleSeedTracker {
    /// Snapshot shape per docs/radicle-provider-api.md — serialized
    /// as-is into `radicle_getSeedStatus` results and `seedStatus`
    /// event payloads.
    struct Status {
        var state: String = "idle"  // fetched | fetching | failed | cancelled | idle
        var inStorage: Bool = false
        var seedersKnown: Int?
        var attemptCount: Int = 0
        var recentAttempts: [[String: Any]] = []
        var progress: [String: Any]?
        var lastError: String?
        var startedAt: Double?
        var finishedAt: Double?

        func payload(rid: String) -> [String: Any] {
            [
                "rid": rid,
                "state": state,
                "inStorage": inStorage,
                "seedersKnown": seedersKnown as Any? ?? NSNull(),
                "attemptCount": attemptCount,
                "recentAttempts": recentAttempts,
                "progress": progress as Any? ?? NSNull(),
                "lastError": lastError as Any? ?? NSNull(),
                "startedAt": startedAt as Any? ?? NSNull(),
                "finishedAt": finishedAt as Any? ?? NSNull(),
            ]
        }
    }

    private let node: RadicleNode
    private var statuses: [String: Status] = [:]
    private var fetchTasks: [String: Task<Void, Never>] = [:]
    /// Origins that called a push method (`seed` / `sync` /
    /// `getSeedStatus`) this session — the only ones that receive
    /// `seedStatus` events, per desktop's broadcaster model.
    private(set) var followingOrigins: Set<String> = []
    /// Bridges register here to relay events into their tab's page.
    /// Keyed by an opaque token so deallocated tabs can unhook.
    private var listeners: [UUID: (String, [String: Any]) -> Void] = [:]

    /// Per-fetch ceiling. Generous: a cold clone from a busy seed can
    /// take a while on cellular; cancellation via unseed stays instant.
    private let fetchTimeoutMs: UInt32 = 120_000

    init(node: RadicleNode) {
        self.node = node
    }

    func addListener(_ token: UUID, _ handler: @escaping (String, [String: Any]) -> Void) {
        listeners[token] = handler
    }

    func removeListener(_ token: UUID) {
        listeners.removeValue(forKey: token)
    }

    func follow(origin: String) {
        followingOrigins.insert(origin)
    }

    func unfollow(origin: String) {
        followingOrigins.remove(origin)
    }

    /// Current snapshot; probes storage on first sight of a rid so
    /// `inStorage` is ground truth even for repos seeded in an earlier
    /// session.
    func status(rid: String) async -> [String: Any] {
        if statuses[rid] == nil {
            var initial = Status()
            initial.inStorage = await isInStorage(rid: rid)
            if initial.inStorage { initial.state = "fetched" }
            // Only cache the probe if no fetch raced us while suspended.
            if statuses[rid] == nil { statuses[rid] = initial }
        }
        return statuses[rid]!.payload(rid: rid)
    }

    /// Start (or restart) the background fetch. Resolves once the task
    /// is launched, with the immediate snapshot — desktop's non-blocking
    /// `radicle_seed` / `radicle_sync` contract.
    func startFetch(rid: String) async -> [String: Any] {
        if fetchTasks[rid] != nil {
            // Fetch already in flight — seed/sync are idempotent.
            return await status(rid: rid)
        }

        var initial = statuses[rid] ?? Status()
        initial.state = "fetching"
        initial.progress = ["phase": "starting"]
        initial.lastError = nil
        initial.startedAt = Date.now.timeIntervalSince1970 * 1000
        initial.finishedAt = nil
        statuses[rid] = initial
        emit(rid: rid)

        fetchTasks[rid] = Task { [weak self, node] in
            let result = await node.cloneRepoWithProgress(
                rid: rid, timeoutMs: self?.fetchTimeoutMs ?? 120_000
            ) { [weak self] event in
                self?.apply(event: event, rid: rid)
            }
            await self?.finishFetch(rid: rid, resultJSON: result)
        }
        return await status(rid: rid)
    }

    /// Cancel any in-flight fetch (the `unseed` path).
    func cancelFetch(rid: String) async {
        guard fetchTasks[rid] != nil else { return }
        _ = await node.cancelCloneJSON(rid: rid)
    }

    // MARK: - Event plumbing

    private func apply(event: RadicleFetchEvent, rid: String) {
        var status = statuses[rid] ?? Status()
        status.progress = event.raw

        switch event.phase {
        case "resolving":
            if let candidates = event.raw["candidates"] as? Int {
                status.seedersKnown = candidates
            }
        case "connecting", "fetching":
            if let total = event.raw["total"] as? Int {
                status.seedersKnown = total
            }
            if event.phase == "fetching" {
                status.attemptCount += 1
            }
        case "peer-failed":
            status.recordAttempt([
                "nid": event.raw["nid"] as? String ?? "",
                "ok": false,
                "error": event.raw["reason"] as? String ?? "unknown",
                "at": Date.now.timeIntervalSince1970 * 1000,
            ])
        case "done":
            // Success attribution: the last `fetching` event named the
            // peer that ended up serving us.
            if let nid = statuses[rid]?.progress?["nid"] as? String {
                status.recordAttempt([
                    "nid": nid, "ok": true,
                    "at": Date.now.timeIntervalSince1970 * 1000,
                ])
            }
        default:
            break
        }

        statuses[rid] = status
        emit(rid: rid)
    }

    private func finishFetch(rid: String, resultJSON: String) async {
        fetchTasks.removeValue(forKey: rid)
        var status = statuses[rid] ?? Status()
        status.finishedAt = Date.now.timeIntervalSince1970 * 1000

        let decoded = (try? JSONSerialization.jsonObject(with: Data(resultJSON.utf8)))
            as? [String: Any] ?? [:]
        if decoded["ok"] as? Bool == true {
            status.state = "fetched"
            status.inStorage = true
            status.lastError = nil
        } else if decoded["cancelled"] as? Bool == true {
            status.state = "cancelled"
        } else {
            status.state = "failed"
            status.lastError = decoded["error"] as? String ?? "fetch failed"
            // A failed fetch may still have landed refs from earlier
            // sessions; keep ground truth honest.
            status.inStorage = await isInStorage(rid: rid)
        }
        statuses[rid] = status
        emit(rid: rid)
    }

    private func emit(rid: String) {
        guard let status = statuses[rid] else { return }
        let payload = status.payload(rid: rid)
        for listener in listeners.values {
            listener(rid, payload)
        }
    }

    private func isInStorage(rid: String) async -> Bool {
        let json = await node.listReposJSON()
        guard let repos = (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
            as? [[String: Any]] else { return false }
        return repos.contains { ($0["rid"] as? String) == rid }
    }
}

private extension RadicleSeedTracker.Status {
    /// Keep the last 5 per-seed results, newest last — spec shape.
    mutating func recordAttempt(_ attempt: [String: Any]) {
        recentAttempts.append(attempt)
        if recentAttempts.count > 5 {
            recentAttempts.removeFirst(recentAttempts.count - 5)
        }
    }
}
