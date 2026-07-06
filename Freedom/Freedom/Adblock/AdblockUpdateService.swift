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
                }
            )
        }

        static var defaultRootDir: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("adblock", isDirectory: true)
        }
    }

    enum Outcome: Equatable {
        case applied(version: Int)
        case notNewer(version: Int)
        case disabled          // trust anchor missing or auto-update off
        case feedUnavailable(String)
        case failed(String)
    }

    private let io: IO
    private let settings: SettingsStore

    /// Minimum spacing between automatic checks (manual `runOnce` ignores it).
    static let checkInterval: TimeInterval = 6 * 60 * 60
    private static let lastCheckKey = "adblock.update.lastCheck"

    init(settings: SettingsStore, io: IO) {
        self.settings = settings
        self.io = io
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
    /// active lists untouched.
    func runOnce() async -> Outcome {
        guard io.trustConfigured else { return .disabled }

        let payload: Data
        do {
            payload = try await io.readFeed()
        } catch {
            // Deliberately does NOT stamp lastCheck: a node that wasn't up
            // yet (common right after launch) shouldn't burn the 6h window —
            // the next foreground retries immediately.
            log.info("feed unavailable: \(String(describing: error), privacy: .public)")
            return .feedUnavailable(String(describing: error))
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
            return .failed("manifest rejected: \(error)")
        }

        do {
            try await stageCompileAndPromote(manifest: manifest)
        } catch {
            log.error("update failed: \(String(describing: error), privacy: .public)")
            cleanupStaging()
            return .failed(String(describing: error))
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

        // Download every shard the manifest lists; reuse the already-applied
        // file when its bytes still hash to the manifest's sha256.
        for list in manifest.platforms.ios.lists {
            for shard in list.shards {
                let data = try await shardData(shard: shard, activeDir: active)
                try data.write(to: staging.appendingPathComponent(shard.filename))
            }
        }

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

    private func shardData(shard: AdblockFeedManifest.IosShard, activeDir: URL) async throws -> Data {
        let existing = activeDir.appendingPathComponent(shard.filename)
        if let data = try? Data(contentsOf: existing), Self.sha256Hex(data) == shard.sha256 {
            return data
        }
        let data = try await io.downloadBlob(shard.ref)
        guard Self.sha256Hex(data) == shard.sha256 else {
            throw AdblockManifestError.malformed(
                "sha256 mismatch for \(shard.filename): expected \(shard.sha256)"
            )
        }
        return data
    }

    private func cleanupStaging() {
        try? FileManager.default.removeItem(
            at: io.rootDir.appendingPathComponent("updated.next", isDirectory: true)
        )
    }

    static func sha256Hex(_ data: Data) -> String {
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
        return BundledAdblockManifest(
            version: String(manifest.generatedAt.prefix(10)),
            generatedAt: manifest.generatedAt,
            libVersion: manifest.engines.map { "\($0.key)@\($0.value)" }.sorted().joined(separator: ", "),
            categories: categories
        )
    }
}
