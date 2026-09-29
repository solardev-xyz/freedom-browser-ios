import XCTest
@testable import Freedom

/// Tezos Domains resolution — desktop `tezos-domains-resolver.test.js`
/// parity: name rules, the ScriptExpr key hash, website-record parsing,
/// and the anchored 2-of-3 quorum with its conflict outcomes.
@MainActor
final class TezosDomainsTests: XCTestCase {
    // MARK: - Fixtures (desktop's mock registry)

    private let endpoints = [URL(string: "https://rpc-one.test")!, URL(string: "https://rpc-two.test")!, URL(string: "https://rpc-three.test")!]

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    }

    private func jsonHex(_ value: Any) -> String {
        json(value).map { String(format: "%02x", $0) }.joined()
    }

    private var proxyScript: [String: Any] {
        [
            "code": [["prim": "storage", "args": [["prim": "pair", "args": [
                ["prim": "address", "annots": ["%contract"]], ["prim": "address", "annots": ["%owner"]],
            ]]]]],
            "storage": ["prim": "Pair", "args": [["string": "KT1GBZmSxmnKJXGMdMLbugPfLyUPmuLSMwKS"], ["string": "KT1BzeXvLtPR83aj5FHemXmia6DmdXkeV3Uk"]]],
        ]
    }

    private var recordType: [String: Any] {
        ["prim": "pair", "args": [["prim": "map", "annots": ["%data"]], ["prim": "option", "annots": ["%expiry_key"]]]]
    }

    private var registryScript: [String: Any] {
        [
            "code": [["prim": "storage", "args": [["prim": "pair", "args": [
                ["prim": "big_map", "args": [["prim": "bytes"], recordType], "annots": ["%records"]],
                ["prim": "big_map", "annots": ["%expiry_map"]],
            ]]]]],
            "storage": ["prim": "Pair", "args": [["int": "1264"], ["int": "1262"]]],
        ]
    }

    private func record(_ entries: [(String, Any)]) -> [String: Any] {
        [
            "prim": "Pair",
            "args": [
                entries.map { ["prim": "Elt", "args": [["string": $0.0], ["bytes": jsonHex($0.1)]]] },
                ["prim": "Some", "args": [["bytes": "aabbcc"]]],
            ],
        ]
    }

    /// Scripted RPC: heads per endpoint, anchor hashes per endpoint, and
    /// the record each endpoint serves; counts requests.
    final class RPC: @unchecked Sendable {
        var record: Any?
        var recordsByEndpoint: [String: Any] = [:]
        var expiry: Any = ["string": "2099-01-01T00:00:00Z"]
        var headLevels: [String: Int] = [:]
        var anchorHashes: [String: String] = [:]
        var failing: Set<String> = []
        private let lock = NSLock()
        private(set) var requests: [String] = []

        func count(matching fragment: String) -> Int {
            lock.withLock { requests.filter { $0.contains(fragment) }.count }
        }

        var fetch: TezosDomainsResolver.Fetch {
            { [self] request in
                let url = request.url!.absoluteString
                lock.withLock { requests.append(url) }
                let origin = "\(request.url!.scheme!)://\(request.url!.host!)"
                func ok(_ value: Any?) -> (status: Int, body: Data) {
                    guard let value else { return (404, Data()) }
                    return (200, try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
                }
                if failing.contains(origin) { throw URLError(.cannotConnectToHost) }
                if url.hasSuffix("/chains/main/chain_id") { return ok("NetXdQprcVkpaWU") }
                if url.hasSuffix("/blocks/head/header") { return ok(["level": headLevels[origin] ?? 1_000]) }
                if let range = url.range(of: #"/blocks/(\d+)/hash$"#, options: .regularExpression) {
                    let level = url[range].split(separator: "/")[1]
                    return ok("\(anchorHashes[origin] ?? "BLockHashSharedByProviders")\(level)")
                }
                if url.contains("KT1F7JKNqwaoLzRsMio1MQC7zv3jG9dHcDdJ/script/normalized") { return ok(TezosDomainsTests.sharedProxy) }
                if url.contains("KT1GBZmSxmnKJXGMdMLbugPfLyUPmuLSMwKS/script/normalized") { return ok(TezosDomainsTests.sharedRegistry) }
                if url.contains("/big_maps/1264/") { return ok(recordsByEndpoint.isEmpty ? record : recordsByEndpoint[origin]) }
                if url.contains("/big_maps/1262/") { return ok(expiry) }
                throw URLError(.badURL)
            }
        }
    }

    nonisolated(unsafe) static var sharedProxy: [String: Any] = [:]
    nonisolated(unsafe) static var sharedRegistry: [String: Any] = [:]

    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var keep: [AnyObject] = []

    override func setUp() async throws {
        Self.sharedProxy = proxyScript
        Self.sharedRegistry = registryScript
    }

    private func resolver(_ rpc: RPC, endpoints: [URL]? = nil) -> TezosDomainsResolver {
        let r = TezosDomainsResolver(endpoints: endpoints ?? self.endpoints, fetch: rpc.fetch, now: { [unowned self] in now })
        keep.append(r)
        return r
    }

    // MARK: - Pure parts

    func testNameRulesDoNotTreatTezAsENS() {
        XCTAssertTrue(TezosDomains.isName("docs.example.tez"))
        XCTAssertTrue(TezosDomains.isName("Example.TEZ"))
        XCTAssertFalse(TezosDomains.isName("example.eth"))
        XCTAssertFalse(TezosDomains.isName("bad..tez"))
        XCTAssertFalse(TezosDomains.isName("bad name.tez"))
        XCTAssertFalse(TezosDomains.isName(".tez"))
        XCTAssertFalse(NameSystem.isSupportedName("example.tez"))
        XCTAssertTrue(NameSystem.isDwebName("example.tez"))
    }

    func testBlake2bVectors() {
        XCTAssertEqual(Blake2b.hash(Data("abc".utf8), outputLength: 32).map { String(format: "%02x", $0) }.joined(),
                       "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319")
        XCTAssertEqual(Blake2b.hash(Data(), outputLength: 32).map { String(format: "%02x", $0) }.joined(),
                       "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8")
        XCTAssertEqual(Blake2b.hash(Data("abc".utf8), outputLength: 64).map { String(format: "%02x", $0) }.joined(),
                       "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
        // More than one block.
        let long = Data(repeating: 0x61, count: 300)
        XCTAssertEqual(Blake2b.hash(long, outputLength: 32).count, 32)
    }

    func testCanonicalScriptExprHash() {
        XCTAssertEqual(TezosDomains.scriptExprHash(Data("awesome-tezos.tez".utf8)), "exprusUkj4PJBxvW1zeyb2JWiGTWF77vDLxMzPBv8LKtHrKGbDzmeB")
    }

    func testPublishedURIParsing() {
        guard case .ok(let ipfs) = TezosDomains.parsePublishedURI("ipfs://bafybeigdyrzt/site/") else { return XCTFail() }
        XCTAssertEqual(ipfs.kind, .ipfs)
        XCTAssertEqual(ipfs.decoded, "bafybeigdyrzt")
        XCTAssertEqual(ipfs.basePath, "/site")
        guard case .unsupported = TezosDomains.parsePublishedURI("ipfs://bafybeigdyrzt", redirect: true) else { return XCTFail() }
        guard case .ok(let web) = TezosDomains.parsePublishedURI("https://example.com/welcome", redirect: true) else { return XCTFail() }
        XCTAssertEqual(web.kind, .web)
        XCTAssertTrue(web.redirect)
        for uri in ["ipns://self.tez", "ipfs://other.tez", "ipns://vitalik.eth", "ipns://self.tez.", "ipns://self%2Etez"] {
            guard case .unsupported(let reason) = TezosDomains.parsePublishedURI(uri) else { return XCTFail(uri) }
            XCTAssertTrue(reason.contains("must reference content, not a name"), uri)
        }
        guard case .ok = TezosDomains.parsePublishedURI("ipns://docs.example.org") else { return XCTFail("DNSLink hosts stay valid") }
        guard case .unsupported = TezosDomains.parsePublishedURI("ftp://x") else { return XCTFail() }
    }

    // MARK: - Quorum

    func testVerifiedResultPrefersRedirectURL() async throws {
        let rpc = RPC()
        rpc.record = record([("web:content_url", "ipfs://bafybeigdyrzt/site"), ("web:redirect_url", "https://example.com/welcome"), ("td:ttl", 120)])
        let result = await resolver(rpc).resolve("example.tez")
        guard case .ok(let record, let trust) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(record.kind, .web)
        XCTAssertEqual(record.uri.absoluteString, "https://example.com/welcome")
        XCTAssertTrue(record.redirect)
        XCTAssertEqual(record.ttl, 120)
        XCTAssertEqual(trust.level, .verified)
        XCTAssertEqual(trust.system, .tezos)
        XCTAssertEqual(trust.k, 3)
        XCTAssertEqual(trust.m, 3)
        XCTAssertEqual(trust.block.number, 992)
    }

    func testIPNSContentKeepsItsBasePath() async throws {
        let rpc = RPC()
        rpc.record = record([("web:content_url", "ipns://docs.example/site")])
        let result = await resolver(rpc, endpoints: Array(endpoints.prefix(2))).resolve("docs.tez")
        guard case .ok(let record, let trust) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(record.kind, .ipns)
        XCTAssertEqual(record.decoded, "docs.example")
        XCTAssertEqual(record.basePath, "/site")
        XCTAssertEqual(trust.level, .verified)
        XCTAssertEqual(trust.m, 2)
    }

    func testConflictingRecordsAreReportedNotPicked() async {
        let rpc = RPC()
        rpc.recordsByEndpoint = [
            "https://rpc-one.test": record([("web:content_url", "ipfs://bafybeigdyrzt/site")]),
            "https://rpc-two.test": record([("web:content_url", "ipfs://bafyother/site")]),
        ]
        let result = await resolver(rpc, endpoints: Array(endpoints.prefix(2))).resolve("contested.tez")
        guard case .conflict(let reason, let groups, let trust) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(reason, "Tezos RPC providers returned conflicting results")
        XCTAssertEqual(trust.level, .conflict)
        XCTAssertEqual(trust.k, 2)
        XCTAssertEqual(trust.m, 1)
        XCTAssertEqual(Set(groups.map(\.value)), ["ipfs://bafybeigdyrzt/site", "ipfs://bafyother/site"])
        XCTAssertEqual(groups.flatMap(\.hosts).sorted(), ["rpc-one.test", "rpc-two.test"])
    }

    func testExpiredDomainIsNotFound() async {
        let rpc = RPC()
        rpc.record = record([("web:content_url", "ipfs://bafybeigdyrzt/site")])
        rpc.expiry = ["string": "2001-01-01T00:00:00Z"]
        let result = await resolver(rpc).resolve("stale.tez")
        XCTAssertEqual(result, .notFound(reason: "domain record expired"))
    }

    func testUnregisteredAndNoWebsiteRecord() async {
        let rpc = RPC()
        rpc.record = nil
        let outcome1 = await resolver(rpc).resolve("nobody.tez")
        XCTAssertEqual(outcome1, .notFound(reason: "domain record not found"))
        rpc.record = record([("td:ttl", 5)])
        let outcome2 = await resolver(rpc).resolve("silent.tez")
        XCTAssertEqual(outcome2, .notFound(reason: "domain has no website record"))
        let outcome3 = await resolver(rpc).resolve("not a name")
        XCTAssertEqual(outcome3, .notFound(reason: "invalid .tez domain"))
    }

    func testOutlierHeadIsExcluded() async {
        let rpc = RPC()
        rpc.record = record([("web:content_url", "ipfs://bafybeigdyrzt/site")])
        rpc.headLevels = ["https://rpc-three.test": 100]
        let result = await resolver(rpc).resolve("anchored.tez")
        guard case .ok(_, let trust) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(trust.level, .verified)
        XCTAssertEqual(trust.k, 2)
        XCTAssertEqual(trust.m, 2)
        XCTAssertFalse(trust.agreed.contains("rpc-three.test"))
    }

    func testTwoProvidersDisagreeingOnTheHeadIsAConflict() async {
        let rpc = RPC()
        rpc.record = record([("web:content_url", "ipfs://bafyEVIL/site")])
        rpc.headLevels = ["https://rpc-two.test": 400]
        let result = await resolver(rpc, endpoints: Array(endpoints.prefix(2))).resolve("split.tez")
        guard case .conflict(let reason, let groups, let trust) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(reason, "Tezos RPC providers disagree about the chain head")
        XCTAssertEqual(trust.k, 2)
        XCTAssertEqual(trust.m, 1)
        XCTAssertEqual(groups.map(\.value), ["chain head #400", "chain head #1000"])
        XCTAssertFalse("\(result)".contains("bafyEVIL"), "no record is read when the head is contested")
    }

    func testDifferentAnchorHashesIsAConflict() async {
        let rpc = RPC()
        rpc.record = record([("web:content_url", "ipfs://bafybeigdyrzt/site")])
        rpc.anchorHashes = ["https://rpc-two.test": "BLockForked"]
        let result = await resolver(rpc, endpoints: Array(endpoints.prefix(2))).resolve("forked.tez")
        guard case .conflict(let reason, let groups, let trust) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(reason, "Tezos RPC providers returned conflicting anchor blocks")
        XCTAssertEqual(trust.m, 1)
        XCTAssertEqual(Set(groups.flatMap(\.hosts)), ["rpc-one.test", "rpc-two.test"])
    }

    func testLoneProviderResolvesUnverifiedAndIsShortCached() async {
        let rpc = RPC()
        rpc.record = record([("web:content_url", "ipfs://bafybeigdyrzt/site"), ("td:ttl", 3_600)])
        rpc.failing = ["https://rpc-two.test", "https://rpc-three.test"]
        let r = resolver(rpc)
        let result = await r.resolve("solo.tez")
        guard case .ok(_, let trust) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(trust.level, .unverified)
        XCTAssertEqual(trust.k, 1)
        let heads = rpc.count(matching: "chain_id")
        _ = await r.resolve("solo.tez")
        XCTAssertEqual(rpc.count(matching: "chain_id"), heads, "served from cache")
        now = now.addingTimeInterval(TezosDomainsResolver.unverifiedTTL + 1)
        _ = await r.resolve("solo.tez")
        XCTAssertGreaterThan(rpc.count(matching: "chain_id"), heads, "an unverified answer is re-checked soon")
    }

    func testConcurrentResolvesShareOneQuorumRound() async {
        let rpc = RPC()
        rpc.record = record([("web:content_url", "ipfs://bafybeigdyrzt/site")])
        let r = resolver(rpc)
        async let first = r.resolve("shared.tez")
        async let second = r.resolve("shared.tez")
        let (a, b) = await (first, second)
        XCTAssertEqual(a, b)
        XCTAssertEqual(rpc.count(matching: "chain_id"), 3)
    }

    func testRegistryDiscoveryIsReusedAcrossNames() async {
        let rpc = RPC()
        rpc.record = record([("web:content_url", "ipfs://bafybeigdyrzt/site")])
        let r = resolver(rpc)
        _ = await r.resolve("first.tez")
        let scripts = rpc.count(matching: "script/normalized")
        XCTAssertEqual(scripts, 6, "proxy + registry per provider")
        _ = await r.resolve("second.tez")
        XCTAssertEqual(rpc.count(matching: "script/normalized"), scripts)
    }

    func testAllProvidersDownIsAnError() async {
        let rpc = RPC()
        rpc.failing = Set(endpoints.map { "\($0.scheme!)://\($0.host!)" })
        let outcome4 = await resolver(rpc).resolve("down.tez")
        XCTAssertEqual(outcome4, .error(reason: "all Tezos RPC providers failed"))
    }

    // MARK: - Façade + URL plumbing

    func testFacadeMapsRecordsToNavigation() async throws {
        let rpc = RPC()
        rpc.record = record([("web:content_url", "ipfs://bafybeigdyrzt/site")])
        let bundle = try ChainStackBundle(orderer: { $0 })
        let ens = ENSResolver(pool: bundle.mainnetPool, settings: bundle.settings, colibri: nil, myotis: nil)
        keep.append(ens)
        let facade = ContentNameResolver(ens: ens, tezos: resolver(rpc))
        keep.append(facade)
        let content = try await facade.resolveContent("site.tez")
        XCTAssertEqual(content.uri.absoluteString, "ipfs://site.tez/")
        XCTAssertEqual(content.contentRef, "bafybeigdyrzt")
        XCTAssertEqual(content.basePath, "/site")
        XCTAssertEqual(content.codec, .ipfs)
        XCTAssertEqual(IpfsSchemeHandler.gatewayStylePath(for: URL(string: "ipfs://site.tez/page")!, resolvedTo: content.contentRef, basePath: content.basePath), "/ipfs/bafybeigdyrzt/site/page")

        rpc.record = record([("web:redirect_url", "https://example.com/welcome")])
        guard case .web(let url, _) = try await facade.resolveName("redirect.tez") else { return XCTFail() }
        XCTAssertEqual(url.absoluteString, "https://example.com/welcome")
        do {
            _ = try await facade.resolveContent("redirect.tez")
            XCTFail("a web record is not content")
        } catch TezosDomainsError.notContent(let target) {
            XCTAssertEqual(target.absoluteString, "https://example.com/welcome")
        }
    }

    func testBrowserURLAndOriginTreatTezAsANameNotENS() {
        guard case .tez(let name, let path)? = BrowserURL.parse("Example.tez/docs?x=1") else { return XCTFail() }
        XCTAssertEqual(name, "example.tez")
        XCTAssertEqual(path, "/docs?x=1")
        XCTAssertEqual(BrowserURL.parse("example.tez")?.url.absoluteString, "tez://example.tez")
        guard case .tez? = BrowserURL.classify(URL(string: "ipfs://example.tez/page")!) else { return XCTFail() }
        guard case .tez? = BrowserURL.classify(URL(string: "https://example.tez/")!) else { return XCTFail() }
        guard case .tez? = BrowserURL.classify(URL(string: "tez://example.tez/a")!) else { return XCTFail() }
        XCTAssertNil(BrowserURL.parse("ens://example.tez"), "ens://name.tez is not ENS")
        XCTAssertTrue(BrowserURL.parse("example.tez")!.isName)
        XCTAssertEqual(BrowserTab.ensNameToReverify(URL(string: "ipfs://example.tez/x")!), "example.tez")

        let bare = OriginIdentity.from(string: "example.tez/app#/x")!
        XCTAssertEqual(bare.key, "example.tez")
        XCTAssertEqual(bare.scheme, .tez)
        XCTAssertTrue(bare.isEligibleForWallet)
        XCTAssertEqual(OriginIdentity.from(string: "ipfs://example.tez/page")?.key, "example.tez")
        XCTAssertEqual(OriginIdentity.from(string: "tez://example.tez/page")?.key, "example.tez")
        XCTAssertEqual(bare.displayString, "tez://example.tez")
    }
}
