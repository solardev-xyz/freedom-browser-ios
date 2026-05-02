import Foundation
import Observation
import OSLog
import WebKit

private let log = Logger(subsystem: "com.browser.Freedom", category: "AdblockService")

/// Compiles bundled WebKit content-blocker JSON via `WKContentRuleListStore`,
/// caches the resulting `WKContentRuleList` instances, and attaches the
/// user-enabled subset to each tab's `WKUserContentController`. Toggles and
/// allowlist edits live-refresh every attached controller; in-flight requests
/// pick up the new rules immediately, already-rendered content needs a reload.
///
/// Per-site allowlist is implemented Brave-iOS-style: when a tab's top URL
/// is on an allowlisted domain (or a subdomain thereof), the block lists are
/// physically detached from that tab's controller. WebKit doesn't reliably
/// honor a separate `ignore-previous-rules` content rule list across attached
/// blockers — Brave learned the same lesson and built per-tab attach/detach.
///
/// Bundled JSON ships under `Resources/adblock/` and is produced by the sibling
/// `freedom-adblock-service` package (Brave's adblock-rs → WebKit JSON).
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
    /// Apple documents `default()` as nullable; in practice it only returns
    /// nil when the device filesystem is unreachable.
    @ObservationIgnored private let store: WKContentRuleListStore?
    @ObservationIgnored private var compiledByCategory: [Category: [WKContentRuleList]] = [:]
    @ObservationIgnored private(set) var manifest: BundledAdblockManifest?
    @ObservationIgnored private var attachments: [Attachment] = []

    init(settings: SettingsStore) {
        self.settings = settings
        self.store = WKContentRuleListStore.default()
    }

    /// Loads `metadata.json`, compiles each shard via `WKContentRuleListStore`.
    /// Idempotent — a second call while compiling or already ready is a no-op.
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

            // Defensive: rewrite any non-canonical allowlist entries
            // (URL-form, www-prefixed, port-suffixed) back to canonical form.
            let normalized = settings.adblockAllowlist.compactMap { normalizedHost($0) }
            let deduped = Array(Set(normalized)).sorted()
            if deduped != settings.adblockAllowlist {
                settings.adblockAllowlist = deduped
            }

            status = .ready
            refreshAllAttachments()
        } catch {
            log.error("compile failed: \(String(describing: error), privacy: .public)")
            status = .failed(message: error.localizedDescription)
        }
    }

    /// Register a controller for live-managed rule list attachment. Initial
    /// attach uses no URL context — the tab calls `updateURL` before its
    /// first navigation. Safe to call before `compileBundledIfNeeded`
    /// finishes — early tabs get caught up by the post-compile refresh.
    /// Idempotent per controller.
    func attach(to controller: WKUserContentController) {
        if attachments.contains(where: { $0.controller === controller }) { return }
        let lists = desiredLists(for: nil)
        for list in lists { controller.add(list) }
        attachments.append(Attachment(controller: controller, currentHost: nil, attachedLists: lists))
    }

    /// Notify the service that a tab's top-level URL changed. Detaches /
    /// re-attaches rule lists when the new host crosses an allowlist
    /// boundary. No-op if the host (post-normalization) hasn't changed.
    func updateURL(_ url: URL?, for controller: WKUserContentController) {
        let host = normalizedHost(url?.host)
        guard let index = attachments.firstIndex(where: { $0.controller === controller }) else { return }
        if attachments[index].currentHost == host { return }
        attachments[index].currentHost = host
        applyTo(attachmentIndex: index)
    }

    // MARK: - Category toggles

    func isEnabled(_ category: Category) -> Bool {
        switch category {
        case .ads:        return settings.adblockAdsEnabled
        case .privacy:    return settings.adblockPrivacyEnabled
        case .cookies:    return settings.adblockCookiesEnabled
        case .annoyances: return settings.adblockAnnoyancesEnabled
        }
    }

    func setEnabled(_ category: Category, _ value: Bool) {
        guard isEnabled(category) != value else { return }
        switch category {
        case .ads:        settings.adblockAdsEnabled = value
        case .privacy:    settings.adblockPrivacyEnabled = value
        case .cookies:    settings.adblockCookiesEnabled = value
        case .annoyances: settings.adblockAnnoyancesEnabled = value
        }
        refreshAllAttachments()
    }

    func ruleCount(for category: Category) -> Int? {
        manifest?.category(category)?.outputRuleCount
    }

    func shardCount(for category: Category) -> Int? {
        manifest?.category(category)?.shards.count
    }

    // MARK: - Per-site allowlist

    var allowlistDomains: [String] {
        settings.adblockAllowlist
    }

    /// Subdomain-aware: returns true if `host` matches an allowlist entry
    /// exactly OR is a subdomain of one (`m.bild.de` ↔ allowlisted `bild.de`).
    func isAllowlisted(host: String?) -> Bool {
        guard let normalized = normalizedHost(host) else { return false }
        return isCovered(host: normalized)
    }

    func isAllowlisted(url: URL?) -> Bool {
        isAllowlisted(host: url?.host)
    }

    func addAllowlist(domain: String) {
        guard let normalized = normalizedHost(domain) else { return }
        addNormalized(normalized)
    }

    func removeAllowlist(domain: String) {
        guard let normalized = normalizedHost(domain) else { return }
        removeNormalized([normalized])
    }

    /// Batched removal — single attachment refresh regardless of how many
    /// domains the caller passes. Used by the swipe-delete handler.
    func removeAllowlist(domains: [String]) {
        let normalized = Set(domains.compactMap { normalizedHost($0) })
        guard !normalized.isEmpty else { return }
        removeNormalized(normalized)
    }

    /// Toggle allowlist state for `host` (exact-match toggle); returns the
    /// new state. The exact-match semantics differ from `isAllowlisted`'s
    /// subdomain-aware check on purpose — toggling adds/removes the host
    /// the user is currently on, even if a parent domain is also allowlisted.
    @discardableResult
    func toggleAllowlist(host: String?) -> Bool {
        guard let normalized = normalizedHost(host) else { return false }
        if settings.adblockAllowlist.contains(normalized) {
            removeNormalized([normalized])
            return false
        }
        addNormalized(normalized)
        return true
    }

    private func addNormalized(_ normalized: String) {
        mutateAllowlist { current in
            guard !current.contains(normalized) else { return current }
            var next = current
            next.append(normalized)
            next.sort()
            return next
        }
    }

    private func removeNormalized(_ normalized: Set<String>) {
        mutateAllowlist { current in
            current.filter { !normalized.contains($0) }
        }
    }

    private func mutateAllowlist(_ transform: ([String]) -> [String]) {
        let current = settings.adblockAllowlist
        let next = transform(current)
        guard next != current else { return }
        settings.adblockAllowlist = next
        refreshAllAttachments()
    }

    /// Used internally to decide attach/detach. Subdomain-aware: returns
    /// true if `host` exactly matches OR is a strict subdomain of any
    /// allowlist entry. `evilbild.de` does NOT match allowlisted `bild.de`
    /// — only entries with a preceding dot count as subdomains.
    private func isCovered(host: String) -> Bool {
        for allowed in settings.adblockAllowlist {
            if host == allowed { return true }
            if host.hasSuffix("." + allowed) { return true }
        }
        return false
    }

    /// Lowercase + strip leading `www.` + extract host from URL-form input.
    /// Returns nil for empty/unparseable input. Only `www.` is stripped —
    /// `news.ycombinator.com` and `ycombinator.com` are different sites.
    func normalizedHost(_ host: String?) -> String? {
        guard let raw = host?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw.contains("://"), let url = URL(string: raw), let h = url.host {
            return canonicalize(h)
        }
        let hostOnly = raw
            .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? raw
        return canonicalize(hostOnly)
    }

    private func canonicalize(_ host: String) -> String? {
        let lower = host.lowercased()
        let noPort = lower.split(separator: ":", maxSplits: 1).first.map(String.init) ?? lower
        guard !noPort.isEmpty, noPort.contains(".") else { return nil }
        if noPort.hasPrefix("www.") {
            let stripped = String(noPort.dropFirst(4))
            return stripped.isEmpty ? nil : stripped
        }
        return noPort
    }

    // MARK: - Attachment refresh

    /// Empty list when status isn't ready, or when `host` is allowlisted
    /// (per-site disable). Otherwise the user-enabled block lists.
    private func desiredLists(for host: String?) -> [WKContentRuleList] {
        guard status == .ready else { return [] }
        if let host, isCovered(host: host) { return [] }
        var lists: [WKContentRuleList] = []
        for category in Category.allCases where isEnabled(category) {
            if let categoryLists = compiledByCategory[category] {
                lists.append(contentsOf: categoryLists)
            }
        }
        return lists
    }

    /// Re-evaluate every live attachment against current state. Prunes
    /// dead refs along the way.
    private func refreshAllAttachments() {
        attachments.removeAll { $0.controller == nil }
        for index in attachments.indices {
            applyTo(attachmentIndex: index)
        }
    }

    private func applyTo(attachmentIndex: Int) {
        guard let controller = attachments[attachmentIndex].controller else { return }
        let current = attachments[attachmentIndex].attachedLists
        let desired = desiredLists(for: attachments[attachmentIndex].currentHost)
        // Identity comparison is sound: rule lists are cached in
        // `compiledByCategory`, so identical desired sets share instances.
        // Skipping the remove/add saves a WebKit IPC round-trip per list —
        // matters most for allowlisted tabs whose desired set stays empty.
        if current.count == desired.count,
           zip(current, desired).allSatisfy({ $0 === $1 }) {
            return
        }
        for old in current { controller.remove(old) }
        for new in desired { controller.add(new) }
        attachments[attachmentIndex].attachedLists = desired
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

    // MARK: - Attachment tracking

    private struct Attachment {
        weak var controller: WKUserContentController?
        var currentHost: String?
        var attachedLists: [WKContentRuleList]
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
