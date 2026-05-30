import Foundation

/// Fetches and caches the chainlist.org chain catalogue. The JSON is
/// multi-MB and updated by the community frequently, so we fetch on
/// demand with a 24h disk cache and tolerate per-entry decode failures
/// so one drifted record doesn't drop the whole list. RPC entries get
/// filtered down to no-key, no-tracking endpoints before the result
/// reaches the chainlist search UI.
final class ChainlistService: Sendable {
    /// Subset of a chainlist entry shaped for `AddChainForm.Prefill`.
    /// `explorerBase` is optional — some chains have no explorer on
    /// chainlist; the manual form lets the user fill it in.
    struct ImportableChain: Equatable, Sendable {
        let chainID: Int
        let displayName: String
        let nativeName: String
        let nativeSymbol: String
        let nativeDecimals: Int
        let explorerBase: String?
        let rpcURLs: [String]
    }

    enum Error: Swift.Error {
        /// Response body decoded but had no valid chain entries.
        case malformedResponse
    }

    typealias Fetcher = @Sendable (URL) async throws -> Data

    static let endpoint = URL(string: "https://chainlist.org/rpcs.json")!

    /// 24h — chainlist changes often enough that longer would silently
    /// miss new chains, but a once-per-day refresh is cheap.
    static let cacheTTL: TimeInterval = 24 * 60 * 60

    private let cacheURL: URL
    private let fetcher: Fetcher
    private let clock: @Sendable () -> Date

    init(
        cacheURL: URL = ChainlistService.defaultCacheURL(),
        fetcher: @escaping Fetcher = ChainlistService.defaultFetcher,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cacheURL = cacheURL
        self.fetcher = fetcher
        self.clock = clock
    }

    /// Fresh cache → parsed cache. Stale/missing cache → fetch and refresh.
    /// On fetch failure (offline, server error, malformed body): fall back
    /// to whatever's on disk regardless of TTL, otherwise propagate the
    /// fetch error so the caller can surface it.
    func chains() async throws -> [ImportableChain] {
        if let fresh = freshCachedData(), let parsed = Self.parse(fresh) {
            return parsed
        }
        let fetchError: Swift.Error
        do {
            let data = try await fetcher(Self.endpoint)
            if let parsed = Self.parse(data) {
                try? writeCache(data)
                return parsed
            }
            fetchError = Error.malformedResponse
        } catch {
            fetchError = error
        }
        if let stale = try? Data(contentsOf: cacheURL), let parsed = Self.parse(stale) {
            return parsed
        }
        throw fetchError
    }

    // MARK: - Cache

    private func freshCachedData() -> Data? {
        let manager = FileManager.default
        guard let attrs = try? manager.attributesOfItem(atPath: cacheURL.path),
              let mtime = attrs[.modificationDate] as? Date,
              let data = try? Data(contentsOf: cacheURL) else {
            return nil
        }
        return clock().timeIntervalSince(mtime) < Self.cacheTTL ? data : nil
    }

    private func writeCache(_ data: Data) throws {
        let directory = cacheURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: cacheURL, options: .atomic)
    }

    // MARK: - Parsing

    /// Returns nil if the JSON envelope itself is unparseable. Returns
    /// an empty array if it parses but every entry was filtered out —
    /// distinguishing "server hiccup / HTML error page" from "no chains
    /// matched our filter" so the caller can decide whether to retry.
    static func parse(_ data: Data) -> [ImportableChain]? {
        let decoder = JSONDecoder()
        guard let wrapped = try? decoder.decode([Failable<RawEntry>].self, from: data) else { return nil }
        return wrapped.compactMap(\.value).compactMap(Self.toImportableChain)
    }

    private static func toImportableChain(_ raw: RawEntry) -> ImportableChain? {
        guard raw.chainId > 0 else { return nil }
        let displayName = raw.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else { return nil }
        guard let native = raw.nativeCurrency, (0...36).contains(native.decimals) else { return nil }
        let nativeName = native.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nativeSymbol = native.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty display strings would render as blank rows in the search
        // UI / chain picker. A drifted chainlist entry shouldn't degrade
        // the surface — skip it.
        guard !nativeName.isEmpty, !nativeSymbol.isEmpty else { return nil }
        let accepted = (raw.rpc ?? []).compactMap(\.value).compactMap(Self.acceptedRPCURL)
        guard !accepted.isEmpty else { return nil }
        let explorerBase = raw.explorers?.first { isHTTPish($0.url) }?.url
        return ImportableChain(
            chainID: raw.chainId,
            displayName: displayName,
            nativeName: nativeName,
            nativeSymbol: nativeSymbol,
            nativeDecimals: native.decimals,
            explorerBase: explorerBase,
            rpcURLs: accepted
        )
    }

    /// Detects `${INFURA_API_KEY}` style placeholders. The pattern is
    /// `${...}` not `$...` — chainlist URLs sometimes embed `$` in path
    /// segments otherwise (e.g., as part of a query string) and we don't
    /// want to reject those.
    private static let apiKeyPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\$\{[^}]+\}"#)
    }()

    private static func acceptedRPCURL(_ entry: RawEntry.RPCEntry) -> String? {
        let url = entry.url
        let range = NSRange(url.startIndex..., in: url)
        if apiKeyPattern.firstMatch(in: url, range: range) != nil {
            return nil
        }
        // Drop URLs chainlist marks as tracking ("limited" / "yes"). An
        // entry with no `tracking` field stays — the data doesn't claim
        // to know either way.
        if let tracking = entry.tracking?.lowercased(), tracking != "none" {
            return nil
        }
        return isHTTPish(url) ? url : nil
    }

    private static func isHTTPish(_ candidate: String) -> Bool {
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else {
            return false
        }
        return true
    }

    // MARK: - Defaults

    static let defaultFetcher: Fetcher = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw URLError(.badServerResponse)
        }
        return data
    }

    static func defaultCacheURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("chainlist", isDirectory: true)
            .appendingPathComponent("rpcs.json")
    }

    // MARK: - Wire shape

    /// Wraps a Decodable so per-entry decode failures don't kill the
    /// surrounding array. The chainlist catalogue has hundreds of
    /// community-maintained entries and one drifted record shouldn't
    /// take down the whole list.
    fileprivate struct Failable<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            do {
                value = try container.decode(T.self)
            } catch {
                value = nil
            }
        }
    }

    fileprivate struct RawEntry: Decodable {
        let name: String
        let chainId: Int
        let nativeCurrency: NativeCurrency?
        let rpc: [Failable<RPCEntry>]?
        let explorers: [Explorer]?

        struct NativeCurrency: Decodable {
            let name: String
            let symbol: String
            let decimals: Int
        }

        /// chainlist.org represents RPC entries inconsistently — most are
        /// objects `{url, tracking, ...}` but legacy entries are bare
        /// URL strings.
        struct RPCEntry: Decodable {
            let url: String
            let tracking: String?

            init(from decoder: Decoder) throws {
                if let single = try? decoder.singleValueContainer(),
                   let stringURL = try? single.decode(String.self) {
                    url = stringURL
                    tracking = nil
                    return
                }
                let keyed = try decoder.container(keyedBy: CodingKeys.self)
                url = try keyed.decode(String.self, forKey: .url)
                tracking = try keyed.decodeIfPresent(String.self, forKey: .tracking)
            }

            enum CodingKeys: String, CodingKey {
                case url, tracking
            }
        }

        struct Explorer: Decodable {
            let url: String
        }
    }
}
