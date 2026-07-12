import XCTest
@testable import Freedom

/// Every case here has a matching desktop fixture in
/// `freedom-browser/src/shared/origin-utils.js`. If a case drifts,
/// cross-platform permission portability is broken.
final class OriginIdentityTests: XCTestCase {
    // MARK: - ENS bare

    func testBareENSNameLowercased() {
        let id = OriginIdentity.from(string: "FOO.ETH")!
        XCTAssertEqual(id.key, "foo.eth")
        XCTAssertEqual(id.scheme, .ens)
        XCTAssertTrue(id.isEligibleForWallet)
    }

    func testBareENSStripsPath() {
        XCTAssertEqual(OriginIdentity.from(string: "1inch.eth/stake#tab")?.key, "1inch.eth")
        XCTAssertEqual(OriginIdentity.from(string: "myapp.box/about")?.key, "myapp.box")
    }

    /// Desktop splits on /, ?, and # so hash-routed SPAs and share-link
    /// queries collapse to the canonical bare name.
    func testBareENSStripsQueryAndFragment() {
        XCTAssertEqual(OriginIdentity.from(string: "myapp.eth#/swap")?.key, "myapp.eth")
        XCTAssertEqual(OriginIdentity.from(string: "myapp.eth?ref=abc")?.key, "myapp.eth")
    }

    func testBareWeiGweiSuffixesAreENS() {
        XCTAssertEqual(OriginIdentity.from(string: "foo.wei/x")?.scheme, .ens)
        XCTAssertEqual(OriginIdentity.from(string: "foo.gwei/x")?.key, "foo.gwei")
    }

    /// Desktop's regex `^[a-z0-9-]+\.(eth|box|wei|gwei)` is not anchored at
    /// the end, so inputs like `foo.ethereum.com` match as ENS. Parity means
    /// we keep this quirk; flag it as a test so future "fixes" to the regex
    /// have to be made on both platforms at once.
    func testBareENSRegexNotAnchoredAtEnd() {
        let id = OriginIdentity.from(string: "foo.ethereum.com/path")!
        XCTAssertEqual(id.key, "foo.ethereum.com")
        XCTAssertEqual(id.scheme, .ens)
    }

    // MARK: - ens:// scheme

    func testEnsSchemeLowercasesAndStopsAtSlashOrHash() {
        XCTAssertEqual(OriginIdentity.from(string: "ens://MyApp.eth/#/pool")?.key, "myapp.eth")
        XCTAssertEqual(OriginIdentity.from(string: "ENS://foo.eth")?.key, "foo.eth")
        XCTAssertEqual(OriginIdentity.from(string: "ens://FOO.eth/a#b")?.key, "foo.eth")
    }

    // MARK: - Dweb schemes

    func testBzzKeepsSchemePreservesRefCase() {
        let id = OriginIdentity.from(string: "bzz://aBC123XYZ/page/here")!
        XCTAssertEqual(id.key, "bzz://aBC123XYZ")
        XCTAssertEqual(id.scheme, .bzz)
        XCTAssertTrue(id.isEligibleForWallet)
    }

    func testBzzSchemeLowercasedRefUntouched() {
        // Scheme goes to lowercase, ref stays verbatim.
        XCTAssertEqual(OriginIdentity.from(string: "BZZ://ABC")?.key, "bzz://ABC")
    }

    func testIpfsIpnsRadNormalizedButIneligible() {
        let ipfs = OriginIdentity.from(string: "ipfs://QmABC/docs")!
        XCTAssertEqual(ipfs.key, "ipfs://QmABC")
        XCTAssertFalse(ipfs.isEligibleForWallet)

        let ipns = OriginIdentity.from(string: "ipns://host.tld/guide")!
        XCTAssertEqual(ipns.key, "ipns://host.tld")
        XCTAssertFalse(ipns.isEligibleForWallet)

        let rad = OriginIdentity.from(string: "rad://z123abc/tree")!
        XCTAssertEqual(rad.key, "rad://z123abc")
        XCTAssertFalse(rad.isEligibleForWallet)
    }

    func testDwebRefStopsAtQueryAndFragment() {
        XCTAssertEqual(OriginIdentity.from(string: "ipfs://QmABC?x=1")?.key, "ipfs://QmABC")
        XCTAssertEqual(OriginIdentity.from(string: "bzz://abc123#frag")?.key, "bzz://abc123")
    }

    // MARK: - Name-host carve-out (desktop origin-utils.js)

    /// The cowswap.eth regression: an ENS name whose contenthash is IPFS
    /// loads as `ipfs://name.eth/...` — the origin must stay the bare ENS
    /// name (wallet-eligible), not fork into an ineligible transport key.
    func testIpfsWithENSHostCarvesOutToENS() {
        let id = OriginIdentity.from(string: "ipfs://cowswap.eth/#/swap")!
        XCTAssertEqual(id.key, "cowswap.eth")
        XCTAssertEqual(id.scheme, .ens)
        XCTAssertTrue(id.isEligibleForWallet)
    }

    func testIpnsWithENSHostCarvesOutToENS() {
        let id = OriginIdentity.from(string: "ipns://myapp.eth/guide")!
        XCTAssertEqual(id.key, "myapp.eth")
        XCTAssertEqual(id.scheme, .ens)
        XCTAssertTrue(id.isEligibleForWallet)
    }

    func testBzzWithENSHostCarvesOutToENSAndLowercases() {
        let id = OriginIdentity.from(string: "bzz://MyApp.eth/page")!
        XCTAssertEqual(id.key, "myapp.eth")
        XCTAssertEqual(id.scheme, .ens)
        XCTAssertTrue(id.isEligibleForWallet)
    }

    func testCarveOutCoversAllNameSuffixes() {
        XCTAssertEqual(OriginIdentity.from(string: "ipfs://foo.box/")?.key, "foo.box")
        XCTAssertEqual(OriginIdentity.from(string: "ipfs://foo.wei/")?.key, "foo.wei")
        XCTAssertEqual(OriginIdentity.from(string: "ipfs://foo.gwei/")?.key, "foo.gwei")
        XCTAssertEqual(OriginIdentity.from(string: "ipfs://foo.gwei/")?.scheme, .ens)
    }

    /// Multi-label names carve out too — `isEnsHost` is a suffix check,
    /// unlike the single-label bare-name regex.
    func testCarveOutAcceptsSubdomainNames() {
        let id = OriginIdentity.from(string: "ipns://docs.myapp.eth/")!
        XCTAssertEqual(id.key, "docs.myapp.eth")
        XCTAssertEqual(id.scheme, .ens)
    }

    /// Desktop's rad:// branch has no name-host carve-out; parity keeps
    /// rad transport-keyed even for `.eth` hosts.
    func testRadIsExcludedFromCarveOut() {
        let id = OriginIdentity.from(string: "rad://foo.eth/tree")!
        XCTAssertEqual(id.key, "rad://foo.eth")
        XCTAssertEqual(id.scheme, .rad)
        XCTAssertFalse(id.isEligibleForWallet)
    }

    /// A CID host that merely contains "eth" must not carve out.
    func testNonNameHostsStayTransportKeyed() {
        XCTAssertEqual(
            OriginIdentity.from(string: "ipfs://bafyeth123/")?.key,
            "ipfs://bafyeth123"
        )
        XCTAssertEqual(OriginIdentity.from(string: "ipfs://bafyeth123/")?.scheme, .ipfs)
    }

    // MARK: - Web URLs

    func testHttpsURLReducesToOrigin() {
        let id = OriginIdentity.from(string: "https://app.uniswap.org/pool/123")!
        XCTAssertEqual(id.key, "https://app.uniswap.org")
        XCTAssertEqual(id.scheme, .https)
        XCTAssertTrue(id.isEligibleForWallet)
    }

    func testHttpsLowercasesSchemeAndHost() {
        XCTAssertEqual(
            OriginIdentity.from(string: "HTTPS://APP.UNISWAP.ORG/foo")?.key,
            "https://app.uniswap.org"
        )
    }

    func testHttpsKeepsNonDefaultPort() {
        XCTAssertEqual(
            OriginIdentity.from(string: "https://app.example.com:8080/foo")?.key,
            "https://app.example.com:8080"
        )
    }

    func testHttpsStripsDefaultPort() {
        XCTAssertEqual(
            OriginIdentity.from(string: "https://app.example.com:443/foo")?.key,
            "https://app.example.com"
        )
    }

    func testHttpOriginIneligible() {
        let id = OriginIdentity.from(string: "http://evil.example.com")!
        XCTAssertEqual(id.key, "http://evil.example.com")
        XCTAssertEqual(id.scheme, .http)
        XCTAssertFalse(id.isEligibleForWallet)
    }

    /// DEBUG builds allow loopback http for dev harnesses (swarm-kit
    /// test centers); Release keeps the plaintext-http refusal. Tests
    /// compile with DEBUG, so this pins the dev-side behavior.
    func testHttpLoopbackEligibleInDebugOnly() {
        for origin in ["http://127.0.0.1:4175", "http://localhost:4175/page"] {
            let id = OriginIdentity.from(string: origin)!
            XCTAssertEqual(id.scheme, .http)
            #if DEBUG
            XCTAssertTrue(id.isEligibleForWallet, origin)
            #else
            XCTAssertFalse(id.isEligibleForWallet, origin)
            #endif
        }
    }

    func testHttpStripsDefaultPort80() {
        XCTAssertEqual(
            OriginIdentity.from(string: "http://evil.example.com:80/foo")?.key,
            "http://evil.example.com"
        )
    }

    // MARK: - Opaque / invalid

    func testEmptyInputReturnsNil() {
        XCTAssertNil(OriginIdentity.from(string: ""))
        XCTAssertNil(OriginIdentity.from(string: "   "))
        XCTAssertNil(OriginIdentity.from(displayURL: nil))
    }

    func testDataURIFallsBackToOther() {
        let id = OriginIdentity.from(string: "data:text/plain,hello")!
        XCTAssertEqual(id.scheme, .other)
        XCTAssertFalse(id.isEligibleForWallet)
    }

    // MARK: - displayURL plumbing

    func testFromDisplayURLRoundTrip() {
        let url = URL(string: "https://app.example.com/foo")!
        XCTAssertEqual(OriginIdentity.from(displayURL: url)?.key, "https://app.example.com")
    }

    // MARK: - displayString (UI rendering)

    func testEnsDisplayStringPrefixesScheme() {
        XCTAssertEqual(OriginIdentity.from(string: "foo.eth")?.displayString, "ens://foo.eth")
    }

    func testNonEnsDisplayStringEqualsKey() {
        XCTAssertEqual(
            OriginIdentity.from(string: "bzz://abc123/x")?.displayString,
            "bzz://abc123"
        )
        XCTAssertEqual(
            OriginIdentity.from(string: "https://x.com/y")?.displayString,
            "https://x.com"
        )
    }
}
