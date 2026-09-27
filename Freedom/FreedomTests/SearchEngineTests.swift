import XCTest
@testable import Freedom

/// Address-bar search: engine table, template validation, URL building
/// (desktop `search-utils.test.js` parity).
final class SearchEngineTests: XCTestCase {
    func testBuiltInEnginesMatchDesktop() {
        XCTAssertEqual(SearchEngine.default, .duckduckgo)
        XCTAssertEqual(SearchEngine.allCases.map(\.rawValue), ["google", "duckduckgo", "bing", "brave", "ecosia", "startpage"])
        XCTAssertEqual(SearchEngine.startpage.template, "https://www.startpage.com/sp/search?query={searchTerms}")
        XCTAssertEqual(SearchEngine.brave.label, "Brave Search")
        for engine in SearchEngine.allCases {
            XCTAssertEqual(SearchEngine.normalizeTemplate(engine.template), engine.template, engine.rawValue)
        }
    }

    func testBuildURLEncodesTheQueryAndFallsBackForUnknownIDs() {
        let url = SearchEngine.buildURL(query: "  how to publish to swarm & ipfs?  ", providerID: "duckduckgo")
        XCTAssertEqual(url?.absoluteString, "https://duckduckgo.com/?q=how%20to%20publish%20to%20swarm%20%26%20ipfs%3F")
        XCTAssertEqual(SearchEngine.buildURL(query: "x", providerID: "google")?.host, "www.google.com")
        // A stale or hand-edited id never breaks search.
        XCTAssertEqual(SearchEngine.buildURL(query: "x", providerID: "constructor")?.host, "duckduckgo.com")
        XCTAssertEqual(SearchEngine.buildURL(query: "x", providerID: "")?.host, "duckduckgo.com")
        XCTAssertNil(SearchEngine.buildURL(query: "   ", providerID: "duckduckgo"))
    }

    func testCustomTemplateRules() {
        XCTAssertEqual(SearchEngine.normalizeTemplate("https://s.example/?q=%s"), "https://s.example/?q={searchTerms}")
        XCTAssertEqual(SearchEngine.normalizeTemplate(" https://s.example/?q={searchTerms} "), "https://s.example/?q={searchTerms}")
        XCTAssertEqual(SearchEngine.normalizeTemplate("http://localhost:8080/?q=%s"), "http://localhost:8080/?q={searchTerms}")
        XCTAssertNil(SearchEngine.normalizeTemplate("http://s.example/?q=%s"), "plain http to a remote host")
        XCTAssertNil(SearchEngine.normalizeTemplate("https://s.example/?q=%s&x={searchTerms}"), "two placeholders")
        XCTAssertNil(SearchEngine.normalizeTemplate("https://s.example/?q=hi"), "no placeholder")
        XCTAssertNil(SearchEngine.normalizeTemplate("https://user:pw@s.example/?q=%s"), "credentials")
        XCTAssertNil(SearchEngine.normalizeTemplate("ftp://s.example/?q=%s"), "scheme")
        XCTAssertNil(SearchEngine.normalizeTemplate(""))
        XCTAssertNil(SearchEngine.normalizeTemplate(String(repeating: "a", count: 2049) + "%s"))
    }

    func testCustomEngineNeedsNameAndValidTemplateElseDefault() {
        let ok = SearchEngine.resolve(providerID: "custom", customName: "Kagi", customTemplate: "https://kagi.com/search?q=%s")
        XCTAssertEqual(ok.label, "Kagi")
        XCTAssertEqual(ok.template, "https://kagi.com/search?q={searchTerms}")
        XCTAssertEqual(SearchEngine.buildURL(query: "a b", providerID: "custom", customName: "Kagi", customTemplate: "https://kagi.com/search?q=%s")?.absoluteString,
                       "https://kagi.com/search?q=a%20b")
        let nameless = SearchEngine.resolve(providerID: "custom", customName: "  ", customTemplate: "https://kagi.com/search?q=%s")
        XCTAssertEqual(nameless.label, "DuckDuckGo")
        let invalid = SearchEngine.resolve(providerID: "custom", customName: "Kagi", customTemplate: "http://kagi.com/search?q=%s")
        XCTAssertEqual(invalid.template, SearchEngine.duckduckgo.template)
    }

    func testAddressBarParserStillRejectsFreeText() {
        // The parser is unchanged: free text is what falls through to search.
        XCTAssertNil(BrowserURL.parse("how to publish to swarm"))
        XCTAssertNil(BrowserURL.parse("swarm"))
        XCTAssertNotNil(BrowserURL.parse("swarm.eth"))
        XCTAssertNotNil(BrowserURL.parse("example.com"))
        XCTAssertNotNil(BrowserURL.parse("localhost"))
    }
}
