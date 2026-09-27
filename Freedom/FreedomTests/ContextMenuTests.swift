import XCTest
@testable import Freedom

final class ContextMenuTests: XCTestCase {
    func testTouchedElementParsing() {
        let parsed = ContextMenuSupport.TouchedElement.parse(["link": "https://a.example/x", "image": "bzz://b.eth/i.png"])
        XCTAssertEqual(parsed.link, URL(string: "https://a.example/x"))
        XCTAssertEqual(parsed.image, URL(string: "bzz://b.eth/i.png"))
        XCTAssertEqual(ContextMenuSupport.TouchedElement.parse(["link": NSNull(), "image": ""]), ContextMenuSupport.TouchedElement())
        XCTAssertEqual(ContextMenuSupport.TouchedElement.parse(nil), ContextMenuSupport.TouchedElement())
        XCTAssertEqual(ContextMenuSupport.TouchedElement.parse(["link": "not a url with spaces"]).link, nil)
    }

    func testSelectionMenuTitleElidesAndCollapses() {
        XCTAssertEqual(ContextMenuSupport.selectionMenuTitle(engine: "DuckDuckGo", selection: "  swarm  "), "Search DuckDuckGo for “swarm”")
        XCTAssertEqual(ContextMenuSupport.selectionMenuTitle(engine: "Kagi", selection: "line one\nline two"), "Search Kagi for “line one line two”")
        let long = String(repeating: "a", count: 40)
        XCTAssertEqual(ContextMenuSupport.selectionMenuTitle(engine: "Bing", selection: long), "Search Bing for “" + String(repeating: "a", count: 32) + "…”")
        XCTAssertNil(ContextMenuSupport.selectionMenuTitle(engine: "Bing", selection: " \n "))
    }

    func testSaveImageOnlyForWebURLs() {
        XCTAssertTrue(ContextMenuSupport.canSaveImage(URL(string: "https://a.example/i.png")!))
        XCTAssertTrue(ContextMenuSupport.canSaveImage(URL(string: "http://a.example/i.png")!))
        XCTAssertFalse(ContextMenuSupport.canSaveImage(URL(string: "bzz://a.eth/i.png")!))
        XCTAssertFalse(ContextMenuSupport.canSaveImage(URL(string: "data:image/png;base64,AAAA")!))
    }
}
