import XCTest
@testable import Freedom

final class FindInPageTests: XCTestCase {
    func testCountScriptEmbedsTheQuerySafely() {
        let script = FindInPage.countScript(for: #"he said "hi" \ <b>\n"#)
        XCTAssertTrue(script.contains(#"["he said \"hi\" \\ <b>\\n"][0]"#), script)
        XCTAssertTrue(script.contains("innerText"))
        XCTAssertTrue(script.contains("toLowerCase()"))
    }

    func testCountScriptForEmptyQueryIsZero() {
        XCTAssertTrue(FindInPage.countScript(for: "").contains(#"[""][0]"#))
    }

    func testLabelPluralizes() {
        XCTAssertEqual(FindInPage.label(count: 1, query: "swarm"), "1 match for “swarm”")
        XCTAssertEqual(FindInPage.label(count: 12, query: "swarm"), "12 matches for “swarm”")
    }
}
