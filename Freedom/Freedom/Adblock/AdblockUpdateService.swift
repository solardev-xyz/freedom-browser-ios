import CryptoKit
import Foundation
import OSLog

private let log = Logger(subsystem: "com.browser.Freedom", category: "AdblockUpdate")

/// Applies filter-list updates from the Swarm feed (see `AdblockUpdateFeed`
/// for the trust anchor and `AdblockUpdateManifest` for verification).
///
/// Mirrors the desktop browser's `update-manager.js`:
///   read feed → verify → download only shards whose hash changed → verify
///   sha256 → stage to `updated.next/` → precompile (the risky step, done
///   before promote) → promote `updated/` → `updated.prev/` (kept for
///   rollback) → activate. Bundled lists remain the permanent floor — a
///   failure at any step leaves the currently-active lists untouched.
///
/// Directory layout under Application Support:
///   adblock/updated/        active update: state.json + metadata.json + shards
///   adblock/updated.next/   staging (transient)
///   adblock/updated.prev/   previous update (rollback reserve)
@MainActor
@Observable
final class AdblockUpdateService {
    /// Feed + filesystem operations, injectable so the pipeline unit-tests
    /// without a node or WebKit. `.live` reads the embedded bee node.
    struct IO {
        var readFeed: @Sendable () async throws -> Data
        var downloadBlob: @Sendable (_ ref: String) async throws -> Data
        var rootDir: URL
        var sigAddress: String
        var trustConfigured: Bool
        /// Compile every staged shard (WKContentRuleListStore) BEFORE the
        /// staging dir is promoted — compile is the step most likely to fail.
        var precompile: (_ manifest: BundledAdblockManifest, _ dir: URL, _ feedVersion: Int) async throws -> Void
        /// Swap the active list source after promote. Must not throw — by
        /// promote time everything is verified and compiled.
        var activate: (_ feedVersion: Int, _ dir: URL) async -> Void
        /// List files the app ships with: a blob whose bytes one of them
        /// already holds is copied instead of downloaded.
        var bundledBlobFiles: @Sendable () -> [URL] = { [] }

        static func live(adblock: AdblockService, bee: BeeAPIClient = BeeAPIClient()) -> IO {
            IO(
                readFeed: {
                    try await bee.getFeedPayload(
                        owner: AdblockUpdateFeed.feedOwnerAddress,
                        topic: AdblockUpdateFeed.feedTopicHex
                    ).payload
                },
                downloadBlob: { try await bee.downloadBytes(reference: $0) },
                rootDir: Self.defaultRootDir,
                sigAddress: AdblockUpdateFeed.manifestSigAddress,
                trustConfigured: AdblockUpdateFeed.isTrustAnchorConfigured,
                precompile: { [weak adblock] manifest, dir, feedVersion in
                    guard let adblock else { throw AdblockError.storeUnavailable }
                    try await adblock.precompileUpdate(manifest: manifest, dir: dir, feedVersion: feedVersion)
                },
                activate: { [weak adblock] feedVersion, dir in
                    await adblock?.activateUpdate(feedVersion: feedVersion, dir: dir)
                },
                bundledBlobFiles: { AdblockService.bundledListFiles() }
            )
        }

        static var defaultRootDir: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("adblock", isDirectory: true)
        }
    }

    enum Outcome: Equatable, Codable {
        case applied(version: Int)
        case notNewer(version: Int)
        case disabled          // trust anchor missing or auto-update off
        case feedUnavailable(String)
        case failed(String)
    }

    /// The last finished check, shown in Settings → Ad Blocking.
    struct CheckResult: Equatable, Codable {
        let date: Date
        let outcome: Outcome
    }

    @ObservationIgnored private let io: IO
    @ObservationIgnored private let settings: SettingsStore

    /// Persisted across launches so Settings can say how the last check went.
    private(set) var lastResult: CheckResult?
    /// A check is in flight (automatic or "Check now").
    private(set) var isChecking = false
    /// The in-flight run: a second caller (launch task, foreground hook,
    /// "Check now") joins it instead of staging into the same directory.
    @ObservationIgnored private var running: Task<Outcome, Never>?

    /// Minimum spacing between automatic checks (manual `runOnce` ignores it).
    static let checkInterval: TimeInterval = 6 * 60 * 60
    /// After a failed download the next automatic check comes this soon
    /// instead of after the full interval: a freshly published list can
    /// take minutes to spread through the network.
    static let failureRetryDelay: TimeInterval = 30 * 60
    /// Attempts per blob before the cycle gives up, and the pause between them.
    static let downloadAttempts = 3
    static var downloadRetryPause: Duration = .seconds(3)
    private static let lastCheckKey = "adblock.update.lastCheck"
    private static let lastResultKey = "adblock.update.lastResult"

    init(settings: SettingsStore, io: IO) {
        self.settings = settings
        self.io = io
        if let data = UserDefaults.standard.data(forKey: Self.lastResultKey) {
            self.lastResult = try? JSONDecoder().decode(CheckResult.self, from: data)
        }
    }

    // MARK: - Applied-state persistence

    /// `state.json` inside an update dir: the applied feed version.
    struct AppliedState: Codable, Equatable {
        let feedVersion: Int
    }

    static func appliedState(rootDir: URL) -> AppliedState? {
        let url = rootDir.appendingPathComponent("updated/state.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(AppliedState.self, from: data)
    }

    /// The list source `AdblockService` should boot from: a previously
    /// applied update if one is on disk, else the bundled lists.
    static func currentSource(rootDir: URL = IO.defaultRootDir) -> AdblockListSource {
        guard let state = appliedState(rootDir: rootDir) else { return .bundled }
        let dir = rootDir.appendingPathComponent("updated", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("metadata.json").path) else {
            return .bundled
        }
        return .updated(feedVersion: state.feedVersion, dir: dir)
    }

    // MARK: - Scheduling

    /// Automatic check: gated on the trust anchor, the user toggle, and the
    /// 6h interval. Called on app start (after bundled compile) and on
    /// foreground.
    @discardableResult
    func checkIfDue() async -> Outcome? {
        guard io.trustConfigured, settings.adblockAutoUpdateEnabled else { return nil }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last >= Self.checkInterval else { return nil }
        return await runOnce()
    }

    /// One full update cycle. Safe to call repeatedly; failures leave the
    /// active lists untouched. A call while a run is in flight waits for
    /// that run's outcome rather than starting a second one.
    @discardableResult
    func runOnce() async -> Outcome {
        if let running { return await running.value }
        let task = Task { await self.performRun() }
        running = task
        isChecking = true
        let outcome = await task.value
        running = nil
        isChecking = false
        if outcome != .disabled {
            record(CheckResult(date: .now, outcome: outcome))
        }
        return outcome
    }

    private func record(_ result: CheckResult) {
        lastResult = result
        if let data = try? JSONEncoder().encode(result) {
            UserDefaults.standard.set(data, forKey: Self.lastResultKey)
        }
    }

    private func performRun() async -> Outcome {
        guard io.trustConfigured else { return .disabled }

        let payload: Data
        do {
            payload = try await io.readFeed()
        } catch {
            // Deliberately does NOT stamp lastCheck: a node that wasn't up
            // yet (common right after launch) shouldn't burn the 6h window —
            // the next foreground retries immediately.
            log.info("feed unavailable: \(String(describing: error), privacy: .public)")
            return .feedUnavailable(error.localizedDescription)
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)

        let applied = Self.appliedState(rootDir: io.rootDir)?.feedVersion
        let manifest: AdblockFeedManifest
        do {
            manifest = try AdblockUpdateManifest.verify(
                payload: payload, sigAddress: io.sigAddress, appliedVersion: applied
            )
        } catch AdblockManifestError.notNewer(let version, _) {
            return .notNewer(version: version)
        } catch {
            log.error("manifest rejected: \(String(describing: error), privacy: .public)")
            return .failed(error.localizedDescription)
        }

        do {
            try await stageCompileAndPromote(manifest: manifest)
        } catch {
            log.error("update failed: \(String(describing: error), privacy: .public)")
            cleanupStaging()
            UserDefaults.standard.set(
                Date().timeIntervalSince1970 - Self.checkInterval + Self.failureRetryDelay,
                forKey: Self.lastCheckKey
            )
            return .failed(error.localizedDescription)
        }

        let dir = io.rootDir.appendingPathComponent("updated", isDirectory: true)
        await io.activate(manifest.version, dir)
        log.info("applied filter-list update version \(manifest.version)")
        return .applied(version: manifest.version)
    }

    // MARK: - Pipeline

    private func stageCompileAndPromote(manifest: AdblockFeedManifest) async throws {
        let fm = FileManager.default
        let root = io.rootDir
        let staging = root.appendingPathComponent("updated.next", isDirectory: true)
        let active = root.appendingPathComponent("updated", isDirectory: true)
        let previous = root.appendingPathComponent("updated.prev", isDirectory: true)

        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        // Fetch every blob the manifest lists. One whose bytes are already
        // on the device — in the applied update or the bundled lists, under
        // any filename — is copied instead: the publisher's shards are
        // deterministic, so an unchanged list keeps its sha256 (desktop
        // `update-manager.js` downloads only shards whose hash changed).
        var blobs = manifest.platforms.ios.lists.flatMap { list in
            list.shards.map { (filename: $0.filename, ref: $0.ref, sha256: $0.sha256) }
        }
        // Scriptlets travel with the lists when the manifest carries them in
        // a format this build reads; otherwise the bundled ones stay in use.
        if let (scriptlets, resources) = Self.scriptletBlobs(manifest) {
            blobs.append((scriptlets.filename, scriptlets.ref, scriptlets.sha256))
            blobs.append((resources.filename, resources.ref, resources.sha256))
        }
        let local = await Self.indexLocalBlobs(Self.localCandidates(activeDir: active) + io.bundledBlobFiles())
        var reused = 0
        for blob in blobs {
            let data: Data
            if let url = local[blob.sha256], let copy = try? Data(contentsOf: url), Self.sha256Hex(copy) == blob.sha256 {
                data = copy
                reused += 1
            } else {
                data = try await download(ref: blob.ref, filename: blob.filename)
                guard Self.sha256Hex(data) == blob.sha256 else {
                    throw AdblockManifestError.malformed("sha256 mismatch for \(blob.filename): expected \(blob.sha256)")
                }
            }
            try data.write(to: staging.appendingPathComponent(blob.filename))
        }
        log.info("v\(manifest.version): \(reused) of \(blobs.count) files already on the device, \(blobs.count - reused) downloaded")

        let updatedManifest = Self.updatedMetadata(from: manifest)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(updatedManifest).write(to: staging.appendingPathComponent("metadata.json"))
        try encoder.encode(AppliedState(feedVersion: manifest.version))
            .write(to: staging.appendingPathComponent("state.json"))

        // Compile from staging BEFORE promote — a WebKit compile failure
        // must leave the active dir untouched.
        try await io.precompile(updatedManifest, staging, manifest.version)

        // Promote: active -> prev, staging -> active.
        try? fm.removeItem(at: previous)
        if fm.fileExists(atPath: active.path) {
            try fm.moveItem(at: active, to: previous)
        }
        do {
            try fm.moveItem(at: staging, to: active)
        } catch {
            // Roll the previous active back so we never end up with nothing.
            if fm.fileExists(atPath: previous.path) {
                try? fm.moveItem(at: previous, to: active)
            }
            throw error
        }
    }

    /// The applied update's list files (not its own bookkeeping).
    static func localCandidates(activeDir: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: activeDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && !["metadata.json", "state.json"].contains($0.lastPathComponent) }
    }

    /// sha256 → file, hashed off the main actor (tens of MB in all). A
    /// hit is re-read and re-verified before use.
    static func indexLocalBlobs(_ files: [URL]) async -> [String: URL] {
        await Task.detached(priority: .utility) {
            var index: [String: URL] = [:]
            for url in files {
                guard let data = try? Data(contentsOf: url) else { continue }
                let hash = sha256Hex(data)
                if index[hash] == nil { index[hash] = url }
            }
            return index
        }.value
    }

    static func scriptletBlobs(
        _ manifest: AdblockFeedManifest
    ) -> (AdblockFeedManifest.IosScriptlets, AdblockFeedManifest.IosResources)? {
        guard let scriptlets = manifest.platforms.ios.scriptlets,
              let resources = manifest.platforms.ios.resources,
              scriptlets.format == ScriptletRuleSet.supportedFormat else { return nil }
        return (scriptlets, resources)
    }

    /// Swarm retrieval of a multi-MB blob fails now and then (a chunk not
    /// yet spread, a dropped connection); retry before failing the cycle.
    private func download(ref: String, filename: String) async throws -> Data {
        var attempt = 1
        while true {
            do {
                return try await io.downloadBlob(ref)
            } catch {
                guard attempt < Self.downloadAttempts else {
                    throw AdblockUpdateError.download(filename: filename, underlying: error)
                }
                log.info("download of \(filename, privacy: .public) failed (attempt \(attempt)): \(String(describing: error), privacy: .public)")
                attempt += 1
                try? await Task.sleep(for: Self.downloadRetryPause)
            }
        }
    }

    private func cleanupStaging() {
        try? FileManager.default.removeItem(
            at: io.rootDir.appendingPathComponent("updated.next", isDirectory: true)
        )
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Derive a `metadata.json` in the bundled-manifest shape from the feed
    /// manifest, so `AdblockService` loads updated and bundled lists through
    /// one code path. Display metadata (title, source URL) joins the desktop
    /// section by `list_id`.
    static func updatedMetadata(from manifest: AdblockFeedManifest) -> BundledAdblockManifest {
        let categories = manifest.platforms.ios.lists.map { list -> BundledAdblockManifest.Entry in
            let desktop = manifest.desktopList(id: list.listId)
            return BundledAdblockManifest.Entry(
                id: list.listId,
                sourceUrl: desktop?.sourceUrl ?? "",
                sourceSha256: desktop?.sha256 ?? "",
                sourceByteSize: desktop?.bytes ?? 0,
                listTitle: desktop?.title,
                listHomepage: nil,
                inputRuleCount: desktop?.ruleCount ?? 0,
                outputRuleCount: list.shards.reduce(0) { $0 + $1.ruleCount },
                shards: list.shards.map {
                    BundledAdblockManifest.Shard(
                        filename: $0.filename, ruleCount: $0.ruleCount, byteSize: $0.bytes
                    )
                }
            )
        }
        let blobs = scriptletBlobs(manifest)
        return BundledAdblockManifest(
            version: String(manifest.generatedAt.prefix(10)),
            generatedAt: manifest.generatedAt,
            libVersion: manifest.engines.map { "\($0.key)@\($0.value)" }.sorted().joined(separator: ", "),
            categories: categories,
            scriptlets: blobs.map { .init(filename: $0.0.filename, format: $0.0.format, ruleCount: $0.0.ruleCount) },
            resources: blobs.map { .init(filename: $0.1.filename, sha256: $0.1.sha256, tag: $0.1.tag, license: $0.1.license) }
        )
    }
}

enum AdblockUpdateError: LocalizedError {
    case download(filename: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .download(let filename, let underlying):
            let reason: String
            switch underlying {
            case BeeAPIClient.Error.notRunning:
                // The feed read just worked, so the node is up: a dropped
                // connection mid-body is a retrieval that broke off.
                reason = "the download broke off. New lists can take a few minutes to spread through the network."
            case BeeAPIClient.Error.notFound:
                reason = "it isn't available on Swarm."
            case BeeAPIClient.Error.timedOut:
                reason = "the Swarm node didn't deliver it in time."
            default:
                reason = underlying.localizedDescription
            }
            return "Couldn't download \(filename): \(reason)"
        }
    }
}
