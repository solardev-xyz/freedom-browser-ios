import XCTest
@testable import Freedom

final class BrowserURLTests: XCTestCase {
    func testBareEthNameParsesAsENS() {
        guard case .ens(let name) = BrowserURL.parse("vitalik.eth") else {
            return XCTFail()
        }
        XCTAssertEqual(name, "vitalik.eth")
    }

    func testEnsSchemeLiteralParses() {
        guard case .ens(let name) = BrowserURL.parse("ens://swarmit.eth") else {
            return XCTFail()
        }
        XCTAssertEqual(name, "swarmit.eth")
    }

    func testHttpsOnEthHostRedirectsToENS() {
        // No DNS `.eth` TLD exists — treat as ENS regardless of scheme.
        guard case .ens(let name) = BrowserURL.parse("https://vitalik.eth") else {
            return XCTFail()
        }
        XCTAssertEqual(name, "vitalik.eth")
    }

    func testENSCaseNormalizesToLowercase() {
        guard case .ens(let name) = BrowserURL.parse("VITALIK.ETH") else {
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
        guard case .ens(let name) = BrowserURL.classify(url) else {
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
}
