import Foundation
import Observation

/// `RadicleNode` is a thin Swift facade over the embedded **Radicle**
/// node (`libradicle-uniffi`, UniFFI scaffolding in the FreedomMobile
/// staticlib). The node is fully P2P: it dials the profile's preferred
/// seeds over Noise and — because the `no-spawn` build serves fetches
/// in-process — peers fetch the phone's refs back over the sessions it
/// opened. That serve path is what makes this node *publish-capable*:
/// COB writes (issues, comments) land in local storage and replicate
/// outward with zero child processes.
///
/// Every UniFFI export is **synchronous and blocking** (no libuv pool as
/// on desktop), so this facade routes each call through a detached task
/// (`blocking(_:)`) and exposes only `async` surface to the app. Results
/// are the raw JSON strings the desktop napi addon returns — the bridge
/// forwards them to `window.radicle` unchanged; only the fields native
/// UI needs are decoded here.
///
/// One process owns at most one node (a global slot in the Rust layer),
/// mirroring desktop: lifecycle is create → start → … → shutdown.
public enum RadicleStatus: String, Sendable {
    case idle, starting, running, stopping, stopped, failed
}

public struct RadicleIdentity: Sendable, Equatable {
    public let did: String
    public let nid: String
    public let alias: String
}

/// Phase-level progress for a repository fetch, decoded from the
/// `ProgressListener` JSON events (`{phase, ...}`).
public struct RadicleFetchEvent: Sendable {
    public let phase: String
    public let raw: [String: Any]

    public init?(json: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let dict = obj as? [String: Any],
              let phase = dict["phase"] as? String else { return nil }
        self.phase = phase
        self.raw = dict
    }
}

@MainActor
@Observable
public final class RadicleNode {
    public private(set) var status: RadicleStatus = .idle
    public private(set) var identity: RadicleIdentity?
    public private(set) var connectedPeers: Int = 0
    /// Last start/shutdown failure, for the node sheet.
    public private(set) var lastError: String?

    public init() {}

    /// Default profile home. File paths may be long — only the control
    /// socket is length-limited, and `start` redirects it (see below).
    public nonisolated static func defaultHome() -> String {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return base.appendingPathComponent("radicle", isDirectory: true).path
    }

    /// Run a blocking UniFFI export off the main actor.
    private static func blocking(_ work: @Sendable @escaping () -> String) async -> String {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    /// First writable temp location whose socket path fits under the
    /// 104-byte `sun_path` cap, or nil if none does (start then fails
    /// with the Rust layer's SUN_LEN error, which is at least honest).
    nonisolated static func shortSocketPath() -> String? {
        var candidates: [String] = []
        // Darwin per-user temp dir: short host path (`/var/folders/…/T/`)
        // when running in the simulator; equals the sandbox tmp on device.
        var buf = [CChar](repeating: 0, count: 1024)
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count) > 0,
           let dir = String(validatingUTF8: buf) {
            candidates.append(dir)
        }
        candidates.append(NSTemporaryDirectory())
        for dir in candidates {
            let path = (dir.hasSuffix("/") ? dir : dir + "/") + "rad.sock"
            if path.utf8.count <= 103,
               FileManager.default.isWritableFile(atPath: dir) {
                return path
            }
        }
        return nil
    }

    private static func decode(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: - Lifecycle

    /// Boot the profile + node runtime. Idempotent per process: a second
    /// call while running reports the Rust layer's "already started".
    public func start(home: String = RadicleNode.defaultHome(), alias: String) async {
        guard status == .idle || status == .stopped || status == .failed else { return }
        status = .starting
        lastError = nil

        // Radicle binds a control socket under the profile home, and
        // unix socket paths cap at 104 bytes on Apple platforms
        // (`sun_path`, so ≤103 usable). The sandbox's Application
        // Support path is far too long, so redirect the socket via
        // RAD_SOCKET — same workaround desktop Freedom uses for macOS.
        // The socket itself is unused on iOS (no `rad` CLI will ever
        // dial it); it just has to bind. On device $TMPDIR fits (~97
        // bytes) but in the SIMULATOR it is the enormous CoreSimulator
        // container path, so probe candidates and take the first that
        // fits — the Darwin per-user temp dir (`/var/folders/…/T/`)
        // covers the simulator.
        if let socketPath = Self.shortSocketPath() {
            setenv("RAD_SOCKET", socketPath, 1)
        }

        let result = await Self.blocking { RadicleKit.start(home: home, alias: alias) }
        let decoded = Self.decode(result)
        if let did = decoded["did"] as? String, !did.isEmpty {
            status = .running
            await refreshIdentity()
            _ = did
        } else {
            status = .failed
            lastError = decoded["error"] as? String ?? "start failed"
        }
    }

    /// Gracefully stop the node and join its thread.
    public func shutdown() async {
        guard status == .running else { return }
        status = .stopping
        let result = await Self.blocking { RadicleKit.shutdown() }
        let decoded = Self.decode(result)
        if decoded["ok"] as? Bool == true {
            status = .stopped
            connectedPeers = 0
        } else {
            status = .failed
            lastError = decoded["error"] as? String ?? "shutdown failed"
        }
    }

    /// Dial the profile's preferred seeds. Returns the number of
    /// connections established within `timeoutMs`.
    @discardableResult
    public func connectSeeds(timeoutMs: UInt32 = 15000) async -> Int {
        let result = await Self.blocking { RadicleKit.connectSeeds(timeoutMs: timeoutMs) }
        let connected = Self.decode(result)["connected"] as? Int ?? 0
        await refreshStatus()
        return connected
    }

    // MARK: - Observable refreshers (node sheet)

    public func refreshIdentity() async {
        let decoded = Self.decode(await Self.blocking { RadicleKit.identity() })
        if let did = decoded["did"] as? String,
           let nid = decoded["nid"] as? String,
           let alias = decoded["alias"] as? String {
            identity = RadicleIdentity(did: did, nid: nid, alias: alias)
        }
    }

    public func refreshStatus() async {
        let decoded = Self.decode(await Self.blocking { RadicleKit.status() })
        connectedPeers = decoded["connectedPeers"] as? Int ?? 0
    }

    // MARK: - Raw JSON pass-throughs (bridge + trackers)

    /// Every call returns the same JSON payload shape the desktop napi
    /// addon produces (`{"error": ...}` on failure).

    public func identityJSON() async -> String {
        await Self.blocking { RadicleKit.identity() }
    }

    public func statusJSON() async -> String {
        await Self.blocking { RadicleKit.status() }
    }

    public func listReposJSON() async -> String {
        await Self.blocking { RadicleKit.listRepos() }
    }

    public func listSeededReposJSON() async -> String {
        await Self.blocking { RadicleKit.listSeededRepos() }
    }

    public func seedersJSON(rid: String) async -> String {
        await Self.blocking { RadicleKit.seeders(rid: rid) }
    }

    public func repoInfoJSON(rid: String) async -> String {
        await Self.blocking { RadicleKit.repoInfo(rid: rid) }
    }

    public func unseedRepoJSON(rid: String) async -> String {
        await Self.blocking { RadicleKit.unseedRepo(rid: rid) }
    }

    /// Seed + fetch with progress. Blocks a detached task for the whole
    /// fetch; `onEvent` is invoked on the main actor per phase event.
    /// Cancel with `cancelClone(rid:)`.
    public func cloneRepoWithProgress(
        rid: String,
        timeoutMs: UInt32,
        onEvent: @MainActor @Sendable @escaping (RadicleFetchEvent) -> Void
    ) async -> String {
        // @unchecked: the Rust fetch thread invokes `onProgress`; the
        // handler is immutable and every touch of app state hops through
        // a MainActor task.
        final class Listener: ProgressListener, @unchecked Sendable {
            let handler: @MainActor @Sendable (RadicleFetchEvent) -> Void
            init(_ handler: @MainActor @Sendable @escaping (RadicleFetchEvent) -> Void) {
                self.handler = handler
            }
            func onProgress(event: String) {
                guard let parsed = RadicleFetchEvent(json: event) else { return }
                let handler = self.handler
                Task { @MainActor in handler(parsed) }
            }
        }
        let listener = Listener(onEvent)
        return await Self.blocking {
            RadicleKit.cloneRepoWithProgress(
                rid: rid, timeoutMs: timeoutMs, onProgress: listener
            )
        }
    }

    public func cancelCloneJSON(rid: String) async -> String {
        await Self.blocking { RadicleKit.cancelClone(rid: rid) }
    }

    // MARK: - COB writes (signing tier)

    public func createIssueJSON(
        rid: String, title: String, description: String, labels: [String]
    ) async -> String {
        let labelsJSON = (try? JSONSerialization.data(withJSONObject: labels))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return await Self.blocking {
            RadicleKit.createIssue(
                rid: rid, title: title, description: description, labelsJson: labelsJSON
            )
        }
    }

    public func commentIssueJSON(
        rid: String, issueId: String, body: String, replyTo: String?
    ) async -> String {
        await Self.blocking {
            RadicleKit.commentIssue(rid: rid, issueId: issueId, body: body, replyTo: replyTo)
        }
    }

    public func editIssueStateJSON(rid: String, issueId: String, state: String) async -> String {
        await Self.blocking {
            RadicleKit.editIssueState(rid: rid, issueId: issueId, state: state)
        }
    }

    public func commentPatchJSON(rid: String, revisionId: String, body: String) async -> String {
        await Self.blocking {
            RadicleKit.commentPatch(rid: rid, revisionId: revisionId, body: body)
        }
    }
}
