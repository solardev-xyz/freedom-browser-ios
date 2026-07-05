import XCTest
@testable import Freedom

final class BrowserURLTests: XCTestCase {
    func testBareEthNameParsesAsENS() {
        guard case .ens(let name, let path) = BrowserURL.parse("vitalik.eth") else {
            return XCTFail()
        }
        XCTAssertEqual(name, "vitalik.eth")
        XCTAssertEqual(path, "")
    }

    func testEnsSchemeLiteralParses() {
        guard case .ens(let name, _) = BrowserURL.parse("ens://swarmit.eth") else {
            return XCTFail()
        }
        XCTAssertEqual(name, "swarmit.eth")
    }

    func testHttpsOnEthHostRedirectsToENS() {
        // No DNS `.eth` TLD exists — treat as ENS regardless of scheme.
        guard case .ens(let name, _) = BrowserURL.parse("https://vitalik.eth") else {
            return XCTFail()
        }
        XCTAssertEqual(name, "vitalik.eth")
    }

    func testENSCaseNormalizesToLowercase() {
        guard case .ens(let name, _) = BrowserURL.parse("VITALIK.ETH") else {
            return XCTFail()
        }
        XCTAssertEqual(name, "vitalik.eth")
    }

    func testENSUrlDisplaysAsEnsScheme() {
        let ens = BrowserURL.ens(name: "vitalik.eth")
        XCTAssertEqual(ens.url.absoluteString, "ens://vitalik.eth")
    }

    func testClassifyRoundTripsENSUrl() {
        let url = URL(string: "ens://vitalik.eth")!
        guard case .ens(let name, _) = BrowserURL.classify(url) else {
            return XCTFail()
        }
        XCTAssertEqual(name, "vitalik.eth")
    }

    func testHttpsOnRegularHostStaysWeb() {
        guard case .web(let url) = BrowserURL.parse("example.com") else {
            return XCTFail()
        }
        XCTAssertEqual(url.absoluteString, "https://example.com")
    }

    func testBzzSchemeStillClassifies() {
        let hex = String(repeating: "a", count: 64)
        guard case .bzz = BrowserURL.parse("bzz://\(hex)") else {
            return XCTFail()
        }
    }

    // MARK: - .wei / .gwei names (WNS / GNS)

    func testBareWeiNameParsesAsENS() {
        guard case .ens(let name, let path) = BrowserURL.parse("wns.wei") else {
            return XCTFail()
        }
        XCTAssertEqual(name, "wns.wei")
        XCTAssertEqual(path, "")
    }

    func testBareGweiNameNormalizesCase() {
        guard case .ens(let name, _) = BrowserURL.parse("Apoorv.GWEI") else {
            return XCTFail()
        }
        XCTAssertEqual(name, "apoorv.gwei")
    }

    func testWeiNameWithPathRoutesToENS() {
        guard case .ens(let name, let path) = BrowserURL.parse("wns.wei/docs") else {
            return XCTFail()
        }
        XCTAssertEqual(name, "wns.wei")
        XCTAssertEqual(path, "/docs")
    }

    func testIpfsOnWeiHostRoutesToENSWithPath() {
        let url = URL(string: "ipfs://wns.wei/x?y=1#z")!
        guard case .ens(let name, let path) = BrowserURL.classify(url) else {
            return XCTFail()
        }
        XCTAssertEqual(name, "wns.wei")
        XCTAssertEqual(path, "/x?y=1#z")
    }

    /// `.box` deliberately stays on plain https — it's a real DNS TLD,
    /// unlike .eth/.wei/.gwei which have no DNS equivalent. See
    /// `NameSystem.navigableSuffixes`.
    func testBoxNameStaysWeb() {
        guard case .web = BrowserURL.parse("myapp.box") else {
            return XCTFail()
        }
    }

    // MARK: - Path preservation through `.eth`-host rewrite

    func testBzzOnEthHostRoutesToENSWithPath() {
        // Bookmarks/history/tab-restore store the resolved transport URL.
        // `classify` must re-route it through `.ens` so the BrowserTab-level
        // resolve runs (populating `currentTrust` for the shield) AND the
        // sub-path survives the round-trip to the resolved transport.
        let url = URL(string: "bzz://vitalik.eth/blog/post1")!
        guard case .ens(let name, let path) = BrowserURL.classify(url) else {
            return XCTFail()
        }
        XCTAssertEqual(name, "vitalik.eth")
        XCTAssertEqual(path, "/blog/post1")
    }

    func testIpfsOnEthHostPreservesQueryAndFragment() {
        let url = URL(string: "ipfs://vitalik.eth/x?y=1#z")!
        guard case .ens(let name, let path) = BrowserURL.classify(url) else {
            return XCTFail()
        }
        XCTAssertEqual(name, "vitalik.eth")
        XCTAssertEqual(path, "/x?y=1#z")
    }

    func testIpnsOnEthHostRoutesToENS() {
        let url = URL(string: "ipns://vitalik.eth/foo")!
        guard case .ens(let name, let path) = BrowserURL.classify(url) else {
            return XCTFail()
        }
        XCTAssertEqual(name, "vitalik.eth")
        XCTAssertEqual(path, "/foo")
    }

    func testBzzOnNonEthHostStaysAsBzz() {
        // Sanity-check the .eth rewrite is host-gated — a 64-char hex
        // swarm ref must still classify as `.bzz`.
        let hex = String(repeating: "a", count: 64)
        let url = URL(string: "bzz://\(hex)")!
        guard case .bzz = BrowserURL.classify(url) else {
            return XCTFail()
        }
    }

    func testParseBareEthNameWithPath() {
        // Typing `vitalik.eth/blog` in the address bar should reach
        // `/blog` after resolution, not root.
        guard case .ens(let name, let path) = BrowserURL.parse("vitalik.eth/blog") else {
            return XCTFail()
        }
        XCTAssertEqual(name, "vitalik.eth")
        XCTAssertEqual(path, "/blog")
    }

    func testEnsURLRoundTripPreservesPath() {
        // .ens → .url → classify → .ens — path survives a write-read cycle
        // through the pseudo `ens://` form used for in-flight display +
        // legacy storage.
        let original = BrowserURL.ens(name: "vitalik.eth", path: "/blog?q=1#a")
        guard case .ens(let name, let path) = BrowserURL.classify(original.url) else {
            return XCTFail()
        }
        XCTAssertEqual(name, "vitalik.eth")
        XCTAssertEqual(path, "/blog?q=1#a")
    }
}
