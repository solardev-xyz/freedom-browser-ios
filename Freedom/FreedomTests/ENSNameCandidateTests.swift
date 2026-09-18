import XCTest
import web3
@testable import Freedom

/// ENSv2 readiness: "any dot-separated string may be an ENS name". The
/// candidate predicate agrees with desktop's `isPotentialEnsName`
/// vectors, and the URL layer applies it only where the user asked for
/// name resolution — a bare DNS name in the address bar keeps HTTPS.
@MainActor
final class ENSNameCandidateTests: XCTestCase {

    // MARK: - Predicate (desktop origin-utils vectors)

    func testCandidateVectorsAgreeWithDesktop() {
        let accepted = [
            "gregskril.com", "🦇.eth", "bücher.eth", "a.co", "ur.integration-tests.eth",
            "test.offchaindemo.eth", "🦇🔊.eth", "RaFFY.eth", "sub.domain.example.org",
        ]
        let rejected = [
            "name", ".eth", "foo..eth", "name.eth/path", "https://gregskril.com",
            "alice@example.com", "a b.eth", "a\u{0}.eth", "", "a:b.eth", "a?b.eth",
            "a#b.eth", "a%b.eth", "a\\b.eth",
        ]
        for value in accepted {
            XCTAssertTrue(NameSystem.isPotentialEnsName(value), "should accept \(value)")
        }
        for value in rejected {
            XCTAssertFalse(NameSystem.isPotentialEnsName(value), "should reject \(value)")
        }
    }

    func testKnownGatewayHosts() {
        for host in ["ipfs.io", "IPFS.IO", "dweb.link", "localhost", "127.0.0.1", "foo.localhost", "gateway.pinata.cloud"] {
            XCTAssertTrue(NameSystem.isKnownIpfsGatewayHost(host), host)
        }
        for host in ["gregskril.com", "my-gateway.example", "vitalik.eth"] {
            XCTAssertFalse(NameSystem.isKnownIpfsGatewayHost(host), host)
        }
    }

    // MARK: - URL.ensName (scheme-aware)

    private func name(_ s: String) -> String? { URL(string: s)?.ensName }

    func testSuffixNamesAreNamesUnderEveryScheme() {
        XCTAssertEqual(name("https://vitalik.eth/x"), "vitalik.eth")
        XCTAssertEqual(name("IPFS://VITALIK.ETH/x"), "vitalik.eth")
        XCTAssertEqual(name("ipns://vitalik.eth"), "vitalik.eth")
        XCTAssertEqual(name("bzz://wns.wei"), "wns.wei")
    }

    func testDnsNamesAreNamesOnlyWhereResolutionWasRequested() {
        XCTAssertEqual(name("ens://gregskril.com"), "gregskril.com")
        XCTAssertEqual(name("ipfs://gregskril.com/docs"), "gregskril.com")
        XCTAssertEqual(name("bzz://gregskril.com/"), "gregskril.com")
        // DNSLink keeps its meaning; DNS keeps its meaning.
        XCTAssertNil(name("ipns://gregskril.com"))
        XCTAssertNil(name("https://gregskril.com"))
        XCTAssertNil(name("http://example.com/"))
    }

    func testGatewayFormAndLiteralHostsAreNotNames() {
        let cid = "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi"
        XCTAssertNil(name("ipfs://ipfs.io/ipfs/\(cid)"))
        XCTAssertNil(name("ipfs://dweb.link/ipfs/\(cid)/a/b"))
        XCTAssertNil(name("ipfs://localhost:8080/ipfs/\(cid)"))
        XCTAssertNil(name("ipfs://127.0.0.1/ipfs/\(cid)"))
        XCTAssertNil(name("ipfs://my-gateway.example:8080/ipfs/\(cid)"))
        XCTAssertNil(name("ipfs://\(cid)/page"))
        XCTAssertNil(name("bzz://" + String(repeating: "a", count: 64) + "/"))
    }

    // MARK: - BrowserURL

    func testExplicitEnsSchemeAcceptsDnsAndUnicodeNames() {
        guard case .ens(let dns, let dnsPath) = BrowserURL.parse("ens://gregskril.com/docs?x=1") else {
            return XCTFail("expected .ens for DNS name")
        }
        XCTAssertEqual(dns, "gregskril.com")
        XCTAssertEqual(dnsPath, "/docs?x=1")
        guard case .ens(let emoji, _) = BrowserURL.parse("ens://🦇.eth") else {
            return XCTFail("expected .ens for emoji name")
        }
        XCTAssertEqual(emoji, "🦇.eth")
        guard case .ens(let idn, _) = BrowserURL.parse("ens://Bücher.eth") else {
            return XCTFail("expected .ens for IDN name")
        }
        XCTAssertEqual(idn, "bücher.eth")
        XCTAssertNil(BrowserURL.parse("ens://foo..eth"))
        XCTAssertNil(BrowserURL.parse("ens://"))
    }

    func testBareUnicodeEthNameWithPathRoutesToENS() {
        guard case .ens(let name, let path) = BrowserURL.parse("🦇.eth/blog") else {
            return XCTFail("expected .ens")
        }
        XCTAssertEqual(name, "🦇.eth")
        XCTAssertEqual(path, "/blog")
    }

    func testBareDnsNameStaysHTTPS() {
        guard case .web(let url) = BrowserURL.parse("gregskril.com") else {
            return XCTFail("expected .web")
        }
        XCTAssertEqual(url.absoluteString, "https://gregskril.com")
    }

    func testContentSchemeDnsHostClassifiesAsENS() {
        guard case .ens(let name, let path) = BrowserURL.parse("ipfs://gregskril.com/docs") else {
            return XCTFail("expected .ens")
        }
        XCTAssertEqual(name, "gregskril.com")
        XCTAssertEqual(path, "/docs")
        guard case .ipns = BrowserURL.parse("ipns://docs.ipfs.tech/install") else {
            return XCTFail("ipns DNSLink must stay .ipns")
        }
        let cid = "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi"
        guard case .ipfs = BrowserURL.parse("ipfs://ipfs.io/ipfs/\(cid)") else {
            return XCTFail("gateway-form must stay .ipfs")
        }
    }

    // MARK: - Resolver: DNS name + IPNS contenthash loads by content key

    private var settings: SettingsStore!
    private var pool: EthereumRPCPool!

    private func resolver(contenthash: Data) -> ENSResolver {
        let defaults = UserDefaults(suiteName: "ENSNameCandidateTests-\(UUID().uuidString)")!
        settings = SettingsStore(defaults: defaults)
        settings.ensResolutionMethod = .quorum
        settings.enableEnsQuorum = false
        let alpha = URL(string: "https://alpha.example.com")!
        settings.ensPublicRpcProviders = [alpha.absoluteString]
        pool = mainnetPool(settings: settings)
        let anchor = AnchorCorroboration(
            pool: pool, settings: settings,
            fetchHead: { _, _, _ in 1000 }, fetchHash: { _, _, _ in "0xblock" }
        )
        return ENSResolver(
            pool: pool, settings: settings, anchor: anchor,
            legRunner: makeLegRunner([
                alpha: .data(resolvedData: abiEncodeBytes(contenthash),
                             resolverAddress: "0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe"),
            ])
        )
    }

    private var ipnsContenthash: Data {
        Data([0xe5, 0x01, 0x01, 0x72, 0x12, 0x20]) + Data(repeating: 0xab, count: 32)
    }

    func testDnsNameWithIpnsContenthashLoadsByContentKey() async throws {
        let result = try await resolver(contenthash: ipnsContenthash).resolveContent("example.com")
        XCTAssertEqual(result.codec, .ipns)
        XCTAssertEqual(result.uri.host, result.contentRef,
                       "ipns://example.com would mean DNSLink; a DNS ENS name loads by key")
        XCTAssertEqual(result.name, "example.com")
    }

    func testEthNameWithIpnsContenthashKeepsNameHost() async throws {
        let result = try await resolver(contenthash: ipnsContenthash).resolveContent("vitalik.eth")
        XCTAssertEqual(result.uri.absoluteString, "ipns://vitalik.eth")
    }
}
