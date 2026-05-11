import XCTest
@testable import Freedom

final class IpfsSchemeHandlerTests: XCTestCase {
    private let exampleCID = "bafybeiaql2jo3fu5b7c4lmpoi5drh5sam7yt652shwdgwbky4o7uw33u2u"

    // MARK: - CID/IPNS-key host path (unchanged from pre-#1)

    func testIpfsCIDHostMapsToGatewayPath() {
        let url = URL(string: "ipfs://\(exampleCID)/index.html")!
        XCTAssertEqual(IpfsSchemeHandler.gatewayStylePath(for: url), "/ipfs/\(exampleCID)/index.html")
    }

    func testIpnsKeyHostMapsToGatewayPath() {
        let key = "k51qzi5uqu5dgr6hxlnvbmhrqnpx4xpzr1mfg9o3pqzr6q3rvkqyhvsd9hjwa6"
        let url = URL(string: "ipns://\(key)/foo")!
        XCTAssertEqual(IpfsSchemeHandler.gatewayStylePath(for: url), "/ipns/\(key)/foo")
    }

    func testNestedIpfsPathPassesThrough() {
        // Relative `/ipfs/<other-cid>/...` fetch arriving as
        // ipfs://<page-cid>/ipfs/<other-cid>/...
        let other = "bafkreih2222222222222222222222222222222222222222222222222"
        let url = URL(string: "ipfs://\(exampleCID)/ipfs/\(other)/x.css")!
        XCTAssertEqual(IpfsSchemeHandler.gatewayStylePath(for: url), "/ipfs/\(other)/x.css")
    }

    // MARK: - ENS-resolved path

    func testENSResolvedIpfsUsesResolvedCIDInPath() {
        let url = URL(string: "ipfs://vitalik.eth/sub/page.html")!
        let path = IpfsSchemeHandler.gatewayStylePath(for: url, resolvedTo: exampleCID)
        XCTAssertEqual(path, "/ipfs/\(exampleCID)/sub/page.html")
    }

    func testENSResolvedIpnsUsesResolvedKeyInPath() {
        let resolvedKey = "k51qzi5uqu5dgr6hxlnvbmhrqnpx4xpzr1mfg9o3pqzr6q3rvkqyhvsd9hjwa6"
        let url = URL(string: "ipns://docs.example.eth/")!
        let path = IpfsSchemeHandler.gatewayStylePath(for: url, resolvedTo: resolvedKey)
        XCTAssertEqual(path, "/ipns/\(resolvedKey)/")
    }

    func testENSResolvedDoesNotOverrideNestedIpfsPath() {
        // Nested-fetch passthrough holds even on an ENS-resolved
        // navigation — the explicit inner CID wins.
        let other = "bafybeih7777777777777777777777777777777777777777777777777"
        let url = URL(string: "ipfs://vitalik.eth/ipfs/\(other)/asset.png")!
        let path = IpfsSchemeHandler.gatewayStylePath(for: url, resolvedTo: exampleCID)
        XCTAssertEqual(path, "/ipfs/\(other)/asset.png")
    }

    // MARK: - Guards

    func testNonIpfsSchemeReturnsNil() {
        let url = URL(string: "bzz://something/")!
        XCTAssertNil(IpfsSchemeHandler.gatewayStylePath(for: url))
    }
}
