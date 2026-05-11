import XCTest
@testable import Freedom

final class BzzSchemeHandlerTests: XCTestCase {
    private let exampleHash = String(repeating: "a", count: 64)

    // MARK: - Hash-host path (unchanged from pre-#1)

    func testHashHostRoutesToBeeGateway() {
        let url = URL(string: "bzz://\(exampleHash)/index.html")!
        let translated = BzzSchemeHandler.localHTTPURL(for: url)
        XCTAssertEqual(translated?.host, "127.0.0.1")
        XCTAssertEqual(translated?.port, BzzSchemeHandler.beeAPIPort)
        XCTAssertEqual(translated?.path, "/bzz/\(exampleHash)/index.html")
    }

    func testBeeGatewayShapedPathPassesThrough() {
        // SPAs that haven't migrated to absolute bzz://<ref>/ still use
        // relative `/bzz/<other-ref>/` fetches — these arrive here as
        // bzz://<page-host>/bzz/<other-ref>/ and route to the inner ref.
        let otherHash = String(repeating: "b", count: 64)
        let url = URL(string: "bzz://anyhost/bzz/\(otherHash)/data.json")!
        let translated = BzzSchemeHandler.localHTTPURL(for: url)
        XCTAssertEqual(translated?.path, "/bzz/\(otherHash)/data.json")
    }

    // MARK: - ENS-resolved path

    func testENSResolvedHostUsesResolvedRefInPath() {
        // `bzz://swarm.eth/` with a resolved Swarm contentRef must form
        // `/bzz/<hex>/` against Bee — the ENS name itself never reaches
        // the upstream gateway.
        let url = URL(string: "bzz://swarm.eth/sub/page.html")!
        let translated = BzzSchemeHandler.localHTTPURL(for: url, resolvedTo: exampleHash)
        XCTAssertEqual(translated?.path, "/bzz/\(exampleHash)/sub/page.html")
    }

    func testENSResolvedRootPathPreserved() {
        let url = URL(string: "bzz://swarm.eth/")!
        let translated = BzzSchemeHandler.localHTTPURL(for: url, resolvedTo: exampleHash)
        // Assert via absoluteString — `URL.path` strips trailing slashes on iOS 17+
        // but the URL on the wire keeps it (which is what Bee actually receives).
        XCTAssertEqual(
            translated?.absoluteString,
            "http://127.0.0.1:\(BzzSchemeHandler.beeAPIPort)/bzz/\(exampleHash)/"
        )
    }

    func testENSResolvedQueryStringPreserved() {
        let url = URL(string: "bzz://swarm.eth/api?foo=bar&baz=qux")!
        let translated = BzzSchemeHandler.localHTTPURL(for: url, resolvedTo: exampleHash)
        XCTAssertEqual(translated?.query, "foo=bar&baz=qux")
    }

    func testENSResolvedDoesNotOverrideBeeGatewayPath() {
        // Even on an ENS-resolved navigation, a nested `/bzz/<ref>/`
        // path inside the URL must route to that ref — matches the
        // existing relative-fetch backwards-compat behavior.
        let nested = String(repeating: "c", count: 64)
        let url = URL(string: "bzz://swarm.eth/bzz/\(nested)/")!
        let translated = BzzSchemeHandler.localHTTPURL(for: url, resolvedTo: exampleHash)
        XCTAssertEqual(
            translated?.absoluteString,
            "http://127.0.0.1:\(BzzSchemeHandler.beeAPIPort)/bzz/\(nested)/"
        )
    }

    // MARK: - Guards

    func testNonBzzSchemeReturnsNil() {
        let url = URL(string: "https://example.com/")!
        XCTAssertNil(BzzSchemeHandler.localHTTPURL(for: url))
    }
}
