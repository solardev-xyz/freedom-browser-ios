import XCTest
@testable import Freedom

final class ExternalLinksTests: XCTestCase {
    func testBrowserSchemesAreNotExternal() {
        for raw in ["https://a.example/", "http://localhost/", "bzz://x.eth/", "ipfs://x.eth/", "ipns://x.eth/",
                    "ens://x.eth", "rad://z6Mk/", "web3://0x0000000000000000000000000000000000000001:1/", "freedom://openlv?x",
                    "ethereum:vitalik.eth@100?value=1e18", "about:blank", "data:text/plain,hi", "blob:https://a.example/uuid", "javascript:void(0)", "file:///x"] {
            XCTAssertFalse(ExternalLinks.isExternal(URL(string: raw)!), raw)
        }
    }

    func testAppSchemesAreExternalAndNamed() {
        XCTAssertTrue(ExternalLinks.isExternal(URL(string: "mailto:a@b.example")!))
        XCTAssertTrue(ExternalLinks.isExternal(URL(string: "tel:+491234")!))
        XCTAssertTrue(ExternalLinks.isExternal(URL(string: "magnet:?xt=urn:btih:abc")!))
        XCTAssertTrue(ExternalLinks.isExternal(URL(string: "myapp://open")!))
        XCTAssertEqual(ExternalLinks.appName(for: URL(string: "mailto:a@b.example")!), "Mail")
        XCTAssertEqual(ExternalLinks.appName(for: URL(string: "TEL:1")!), "Phone")
        XCTAssertEqual(ExternalLinks.appName(for: URL(string: "sms:1")!), "Messages")
        XCTAssertEqual(ExternalLinks.appName(for: URL(string: "magnet:?x")!), "a torrent app")
        XCTAssertEqual(ExternalLinks.appName(for: URL(string: "myapp://open")!), "another app (myapp)")
    }

    func testPromptSentence() {
        let external = SitePermissionRequest(origin: "https://a.example", kinds: [.externalApps], detail: "Mail") { _, _ in }
        XCTAssertEqual(external.sentence, "wants to open Mail")
        let media = SitePermissionRequest(origin: "https://a.example", kinds: [.camera, .microphone]) { _, _ in }
        XCTAssertEqual(media.sentence, "wants to use your camera and microphone")
        XCTAssertEqual(SitePermissionKind.externalApps.label, "Open other apps")
    }
}
