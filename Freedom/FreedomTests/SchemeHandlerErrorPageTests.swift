import XCTest
@testable import Freedom

final class SchemeHandlerErrorPageTests: XCTestCase {
    func testCodecMismatchMentionsNameAndBothSchemes() {
        let html = SchemeHandlerErrorPage.render(.codecMismatch(
            requestedScheme: "bzz",
            resolvedScheme: "ipfs",
            name: "vitalik.eth"
        ))
        XCTAssertTrue(html.contains("vitalik.eth"))
        XCTAssertTrue(html.contains("bzz"))
        XCTAssertTrue(html.contains("ipfs"))
        // Body should suggest the correctly-coded URL.
        XCTAssertTrue(html.contains("ipfs://vitalik.eth/"))
    }

    func testCodecMismatchEscapesHTMLInName() {
        // Defensive: an attacker-controlled name shouldn't be able to
        // break out of the HTML body (no path through the resolver
        // emits these today, but the renderer should still escape).
        let html = SchemeHandlerErrorPage.render(.codecMismatch(
            requestedScheme: "bzz",
            resolvedScheme: "ipfs",
            name: "<script>alert(1)</script>.eth"
        ))
        XCTAssertFalse(html.contains("<script>alert"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testResolutionFailedIncludesMessage() {
        let html = SchemeHandlerErrorPage.render(.resolutionFailed(
            name: "broken.eth",
            message: "all providers errored"
        ))
        XCTAssertTrue(html.contains("broken.eth"))
        XCTAssertTrue(html.contains("all providers errored"))
    }

    func testRendersValidHTMLShell() {
        let html = SchemeHandlerErrorPage.render(.resolutionFailed(name: "x.eth", message: ""))
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("<title>"))
        XCTAssertTrue(html.contains("</html>"))
    }
}
