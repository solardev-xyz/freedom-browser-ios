import Foundation
import Observation
import OSLog
import WebKit

private let log = Logger(subsystem: "com.browser.Freedom", category: "AdblockService")

/// Compiles bundled WebKit content-blocker JSON via `WKContentRuleListStore`,
/// caches the resulting `WKContentRuleList` instances, and attaches the
/// user-enabled subset to each new tab's `WKUserContentController`.
///
/// Bundled artifacts live under `Resources/adblock/` and are produced by the
/// sibling `freedom-adblock-service` package (Brave's adblock-rs → WebKit JSON,
/// sharded under iOS 17's size-crash threshold). Phase 1 ships compile-and-attach
/// only; runtime updates over Swarm Feed land in phase 3.
///
/// Toggle semantics: settings changes apply to NEW tabs at creation time.
/// Existing tabs keep their attached rule lists until they're closed.
@MainActor
@Observable
final class AdblockService {
    enum Category: String, CaseIterable, Identifiable, Codable {
        /// Raw value matches the `id` field in the bundled `metadata.json`.
        case ads = "easylist"
        case privacy = "easyprivacy"
        case cookies = "easylist-cookies"
        case annoyances = "easylist-annoyances"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .ads:        return "Block ads"
            case .privacy:    return "Block trackers"
            case .cookies:    return "Block cookie banners"
            case .annoyances: return "Block other annoyances"
            }
        }

        var subtitle: String {
            switch self {
            case .ads:        return "EasyList"
            case .privacy:    return "EasyPrivacy"
            case .cookies:    return "Fanboy's Cookiemonster"
            case .annoyances: return "Fanboy's Annoyances"
            }
        }
    }

    enum Status: Equatable {
        case idle
        case compiling
        case ready
        case failed(message: String)
    }

    private(set) var status: Status = .idle

    @ObservationIgnored private let settings: SettingsStore
    /// Apple documents `default()` as nullable but in practice it only returns
    /// nil when the device's filesystem is unreachable. Cached at init so each
    /// compile/lookup doesn't re-fetch and so the failure case surfaces once.
    @ObservationIgnored private let store: WKContentRuleListStore?
    @ObservationIgnored private var compiledByCategory: [Category: [WKContentRuleList]] = [:]
    @ObservationIgnored private(set) var manifest: BundledAdblockManifest?

    init(settings: SettingsStore) {
        self.settings = settings
        self.store = WKContentRuleListStore.default()
    }

    /// Loads `metadata.json`, compiles each shard via `WKContentRuleListStore`,
    /// and stores the compiled lists in memory. Idempotent — a second call
    /// while compiling or already ready is a no-op.
    func compileBundledIfNeeded() async {
        guard status == .idle else { return }
        guard store != nil else {
            status = .failed(message: "WKContentRuleListStore unavailable")
            log.error("WKContentRuleListStore.default() returned nil")
            return
        }
        status = .compiling

        do {
            let manifest = try loadManifest()
            self.manifest = manifest

            for category in Category.allCases {
                guard let entry = manifest.category(category) else {
                    log.warning("manifest missing \(category.rawValue, privacy: .public)")
                    continue
                }
                var compiled: [WKContentRuleList] = []
                for shard in entry.shards {
                    let list = try await compile(category: category, shard: shard)
                    compiled.append(list)
                }
                compiledByCategory[category] = compiled
                log.info("compiled \(compiled.count) shard(s) for \(category.rawValue, privacy: .public)")
            }
            status = .ready
        } catch {
            log.error("compile failed: \(String(describing: error), privacy: .public)")
            status = .failed(message: error.localizedDescription)
        }
    }

    /// Add the user-enabled rule lists to a fresh tab's user content controller.
    /// Called once at `BrowserTab.init`. No-op until `compileBundledIfNeeded`
    /// has succeeded — early tabs created before compile completes get no
    /// blocking on this navigation, which is fine: the bundle takes ~1s to
    /// compile cold and milliseconds warm (the `WKContentRuleListStore`
    /// disk cache survives across launches under stable identifiers).
    func attach(to controller: WKUserContentController) {
        guard status == .ready else { return }
        for category in Category.allCases where isEnabled(category) {
            for list in compiledByCategory[category] ?? [] {
                controller.add(list)
            }
        }
    }

    func isEnabled(_ category: Category) -> Bool {
        switch category {
        case .ads:        return settings.adblockAdsEnabled
        case .privacy:    return settings.adblockPrivacyEnabled
        case .cookies:    return settings.adblockCookiesEnabled
        case .annoyances: return settings.adblockAnnoyancesEnabled
        }
    }

    func setEnabled(_ category: Category, _ value: Bool) {
        switch category {
        case .ads:        settings.adblockAdsEnabled = value
        case .privacy:    settings.adblockPrivacyEnabled = value
        case .cookies:    settings.adblockCookiesEnabled = value
        case .annoyances: settings.adblockAnnoyancesEnabled = value
        }
    }

    func ruleCount(for category: Category) -> Int? {
        manifest?.category(category)?.outputRuleCount
    }

    func shardCount(for category: Category) -> Int? {
        manifest?.category(category)?.shards.count
    }

    // MARK: - Compile pipeline

    private func compile(
        category: Category,
        shard: BundledAdblockManifest.Shard
    ) async throws -> WKContentRuleList {
        let identifier = "freedom-adblock.\(shard.filenameStem)"
        if let cached = await lookUp(identifier: identifier) {
            return cached
        }
        let json = try loadShardJSON(filename: shard.filename)
        return try await compile(identifier: identifier, json: json)
    }

    private func lookUp(identifier: String) async -> WKContentRuleList? {
        // `lookUpContentRuleList` reports cache miss as an error; we don't
        // care to distinguish that from real I/O failure here — a subsequent
        // compile will surface anything genuinely wrong.
        guard let store else { return nil }
        return await withCheckedContinuation { cont in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                cont.resume(returning: list)
            }
        }
    }

    private func compile(identifier: String, json: String) async throws -> WKContentRuleList {
        guard let store else { throw AdblockError.storeUnavailable }
        return try await withCheckedThrowingContinuation { cont in
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { list, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                guard let list else {
                    cont.resume(throwing: AdblockError.compileFailed(identifier))
                    return
                }
                cont.resume(returning: list)
            }
        }
    }

    // MARK: - Bundle I/O

    private func loadManifest() throws -> BundledAdblockManifest {
        let url = try resourceURL(forResource: "metadata", withExtension: "json")
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(BundledAdblockManifest.self, from: data)
    }

    private func loadShardJSON(filename: String) throws -> String {
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        let url = try resourceURL(forResource: stem, withExtension: ext)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Look up a resource that may be in `Resources/adblock/` (folder
    /// reference) or flattened to the bundle root (group). Try both so the
    /// service works regardless of how the Xcode project references the
    /// directory.
    private func resourceURL(forResource name: String, withExtension ext: String) throws -> URL {
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "adblock") {
            return url
        }
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }
        throw AdblockError.resourceMissing("\(name).\(ext)")
    }
}

enum AdblockError: LocalizedError {
    case resourceMissing(String)
    case compileFailed(String)
    case storeUnavailable

    var errorDescription: String? {
        switch self {
        case .resourceMissing(let name): return "Bundled adblock resource not found: \(name)"
        case .compileFailed(let id):     return "Failed to compile content rule list: \(id)"
        case .storeUnavailable:          return "WKContentRuleListStore unavailable"
        }
    }
}

/// Mirrors the `metadata.json` produced by `freedom-adblock-service`.
/// `list_expires` is omitted intentionally — upstream serializes a Rust
/// enum (`{"Days": 4}`) that we don't need on the iOS side.
struct BundledAdblockManifest: Codable {
    let version: String
    let generatedAt: String
    let libVersion: String
    let categories: [Entry]

    struct Entry: Codable {
        let id: String
        let sourceUrl: String
        let sourceSha256: String
        let sourceByteSize: Int
        let listTitle: String?
        let listHomepage: String?
        let inputRuleCount: Int
        let outputRuleCount: Int
        let shards: [Shard]
    }

    struct Shard: Codable {
        let filename: String
        let ruleCount: Int
        let byteSize: Int

        var filenameStem: String {
            (filename as NSString).deletingPathExtension
        }
    }

    func category(_ category: AdblockService.Category) -> Entry? {
        categories.first { $0.id == category.rawValue }
    }
}
