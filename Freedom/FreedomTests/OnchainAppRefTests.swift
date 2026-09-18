import XCTest
import web3
@testable import Freedom

/// URL shapes, permission keys and the `html()` decode for contract-hosted
/// apps. Vectors match desktop `onchain-app-protocol.test.js` and
/// `origin-utils.test.js`.
final class OnchainAppRefTests: XCTestCase {
    private let zswap = "0x00000095643CFfA7D9fae407a84dfCB6406456c6"

    func testFriendlyFormParsesWithDefaultChain() throws {
        let (app, tail) = try XCTUnwrap(OnchainAppRef.parse(URL(string: "web3://\(zswap.lowercased())/")!))
        XCTAssertEqual(app.address, zswap, "address is checksummed")
        XCTAssertEqual(app.chainID, 1)
        XCTAssertEqual(tail, "")
    }

    func testFriendlyFormWithChainAndTail() throws {
        let (app, tail) = try XCTUnwrap(OnchainAppRef.parse(URL(string: "web3://\(zswap):100/swap?x=1#frag")!))
        XCTAssertEqual(app.chainID, 100)
        XCTAssertEqual(tail, "/swap?x=1#frag")
    }

    func testCanonicalFormParses() throws {
        let (app, tail) = try XCTUnwrap(OnchainAppRef.parse(URL(string: "web3://\(zswap.lowercased()).eip155-8453/app")!))
        XCTAssertEqual(app.chainID, 8453)
        XCTAssertEqual(app.address, zswap)
        XCTAssertEqual(tail, "/app")
    }

    func testRejectsMalformedHosts() {
        for bad in ["web3://not-an-address/", "web3://\(zswap).eip155-x/", "web3://\(zswap).eip155-1:5/",
                    "web3://0x1234/", "https://\(zswap)/", "web3://\(zswap):0/"] {
            XCTAssertNil(OnchainAppRef.parse(URL(string: bad)!), bad)
        }
    }

    func testDisplayAndCanonicalForms() throws {
        let app = try XCTUnwrap(OnchainAppRef(address: zswap.lowercased(), chainID: 1))
        XCTAssertEqual(app.displayURL().absoluteString, "web3://\(zswap)/")
        XCTAssertEqual(app.displayURL(tail: "/swap").absoluteString, "web3://\(zswap)/swap")
        XCTAssertEqual(app.canonicalURL().absoluteString, "web3://\(zswap.lowercased()).eip155-1/")
        let gnosis = try XCTUnwrap(OnchainAppRef(address: zswap, chainID: 100))
        XCTAssertEqual(gnosis.displayURL().absoluteString, "web3://\(zswap):100/")
        XCTAssertEqual(gnosis.canonicalURL(tail: "swap").absoluteString, "web3://\(zswap.lowercased()).eip155-100/swap")
        // Round trips.
        XCTAssertEqual(OnchainAppRef.parse(gnosis.canonicalURL(tail: "/a?b#c"))?.app, gnosis)
        XCTAssertEqual(OnchainAppRef.parse(gnosis.displayURL(tail: "/a?b#c"))?.tail, "/a?b#c")
    }

    func testPermissionKeyMatchesDesktop() throws {
        let mainnet = try XCTUnwrap(OnchainAppRef(address: zswap, chainID: 1))
        XCTAssertEqual(mainnet.permissionKey, "web3://\(zswap.lowercased())")
        let gnosis = try XCTUnwrap(OnchainAppRef(address: zswap, chainID: 100))
        XCTAssertEqual(gnosis.permissionKey, "web3://\(zswap.lowercased()):100")
        // Desktop origin-utils vectors, both URL shapes.
        XCTAssertEqual(OriginIdentity.from(string: "web3://\(zswap)/")?.key, "web3://\(zswap.lowercased())")
        XCTAssertEqual(OriginIdentity.from(string: "web3://\(zswap.lowercased()).eip155-100/swap")?.key, "web3://\(zswap.lowercased()):100")
        XCTAssertEqual(OriginIdentity.from(string: "web3://\(zswap).eip155-1/x?y#z")?.key, "web3://\(zswap.lowercased())")
        XCTAssertEqual(OriginIdentity.from(string: "web3://\(zswap)/")?.scheme, .web3)
        XCTAssertTrue(OriginIdentity.from(string: "web3://\(zswap)/")!.isEligibleForWallet)
        XCTAssertNil(OriginIdentity.from(string: "web3://nope/"))
    }

    func testBrowserURLClassifiesBothForms() throws {
        guard case .onchain(let app, let path) = try XCTUnwrap(BrowserURL.parse("web3://\(zswap):100/swap")) else {
            return XCTFail("expected .onchain")
        }
        XCTAssertEqual(app.chainID, 100)
        XCTAssertEqual(path, "/swap")
        guard case .onchain(let canon, _) = try XCTUnwrap(BrowserURL.classify(URL(string: "web3://\(zswap.lowercased()).eip155-100/")!)) else {
            return XCTFail("expected .onchain")
        }
        XCTAssertEqual(canon, app)
        XCTAssertEqual(BrowserURL.onchain(app: app, path: "/swap").url.absoluteString, "web3://\(zswap):100/swap")
    }

    // MARK: - html() decode

    private func encodeString(_ s: String) -> String {
        let encoder = ABIFunctionEncoder("_")
        try! encoder.encode(s)
        return Data(try! encoder.encoded().dropFirst(4)).web3.hexString
    }

    func testDecodeHTMLRoundTrip() throws {
        let html = "<!doctype html><title>zSwap</title><p>hi ü 🦇</p>"
        XCTAssertEqual(try OnchainAppRef.decodeHTML(encodeString(html)), html)
    }

    func testDecodeHTMLRejectsMalformedAndOversized() {
        XCTAssertThrowsError(try OnchainAppRef.decodeHTML("0x"))
        XCTAssertThrowsError(try OnchainAppRef.decodeHTML("zz"))
        XCTAssertThrowsError(try OnchainAppRef.decodeHTML("0x1234"))
        // Encoded size over the cap fails before any decode is attempted.
        let huge = "0x" + String(repeating: "00", count: OnchainAppRef.maxHTMLBytes + 96)
        XCTAssertThrowsError(try OnchainAppRef.decodeHTML(huge)) { error in
            XCTAssertEqual(error as? OnchainAppError, .tooLarge)
        }
    }

    func testHtmlHashIsKeccakOfUTF8() {
        XCTAssertEqual(
            OnchainAppRef.htmlHash(""),
            "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
        )
        XCTAssertEqual(OnchainAppRef.htmlHash("<p>a</p>").count, 66)
    }
}
