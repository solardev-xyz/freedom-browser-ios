import XCTest
@testable import Freedom

/// What the app does with a URL from outside: pairing link, page, or not ours.
final class IncomingLinkTests: XCTestCase {
    func testPairingLinkWins() {
        let link = IncomingLink.classify(URL(string: "freedom://openlv#openlv%3A%2F%2Fabc")!)
        XCTAssertEqual(link, .openLV(uri: "openlv://abc"))
        XCTAssertEqual(IncomingLink.classify(URL(string: "openlv://abc")!), .openLV(uri: "openlv://abc"))
    }

    func testPagesOpenAsBrowserURLs() throws {
        guard case .page(.web(let web)) = IncomingLink.classify(URL(string: "https://example.com/a?b=1")!) else { return XCTFail("web") }
        XCTAssertEqual(web.absoluteString, "https://example.com/a?b=1")
        guard case .page(.ens(let name, let path, let codec)) = IncomingLink.classify(URL(string: "bzz://vitalik.eth/blog")!) else { return XCTFail("ens") }
        XCTAssertEqual(name, "vitalik.eth"); XCTAssertEqual(path, "/blog"); XCTAssertEqual(codec, .bzz)
        guard case .page(.ipfs) = IncomingLink.classify(URL(string: "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/")!) else { return XCTFail("ipfs") }
        guard case .page(.ens(let dns, _, _)) = IncomingLink.classify(URL(string: "ens://gregskril.com")!) else { return XCTFail("ens scheme") }
        XCTAssertEqual(dns, "gregskril.com")
    }

    func testPaymentLinksGoToSend() {
        let url = URL(string: "ethereum:0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045@100?value=1e18")!
        XCTAssertEqual(IncomingLink.classify(url), .payment(url))
    }

    func testNotOursIsIgnored() {
        for raw in ["freedom://something-else", "mailto:a@b.example", "tel:+491234", "myapp://open", "file:///etc/hosts", "javascript:alert(1)"] {
            XCTAssertEqual(IncomingLink.classify(URL(string: raw)!), .unsupported, raw)
        }
    }
}
