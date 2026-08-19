import XCTest
@testable import Freedom

/// URL-parsing and pagination rules of the `rad:` scheme handler —
/// desktop `radicle-api-protocol.js` parity, including the traversal
/// rejections that keep a page inside its repo scope.
final class RadSchemeHandlerTests: XCTestCase {
    private let rid = "z3gqcJUoA1n9HaHKufZs5FCSGazv5"

    func testParsesUrnAndSchemeForms() throws {
        for form in ["rad:\(rid)/tree/abc", "rad://\(rid)/tree/abc"] {
            let parsed = try XCTUnwrap(RadSchemeHandler.parse(form), form)
            XCTAssertEqual(parsed.rid, "rad:\(rid)")
            XCTAssertEqual(parsed.segments, ["tree", "abc"])
        }
    }

    func testBareRidHasNoSegments() throws {
        let parsed = try XCTUnwrap(RadSchemeHandler.parse("rad:\(rid)"))
        XCTAssertEqual(parsed.segments, [])
        XCTAssertTrue(parsed.query.isEmpty)
    }

    func testQueryParsing() throws {
        let parsed = try XCTUnwrap(
            RadSchemeHandler.parse("rad:\(rid)/commits?parent=abc&page=2&perPage=10")
        )
        XCTAssertEqual(parsed.query["parent"], "abc")
        XCTAssertEqual(parsed.query["page"], "2")
        XCTAssertEqual(parsed.query["perPage"], "10")
    }

    func testTrailingSlashIsLegitimate() throws {
        let parsed = try XCTUnwrap(RadSchemeHandler.parse("rad:\(rid)/tree/abc/"))
        XCTAssertEqual(parsed.segments, ["tree", "abc"])
    }

    func testPercentDecodedSegments() throws {
        let parsed = try XCTUnwrap(
            RadSchemeHandler.parse("rad:\(rid)/blob/abc/docs%20and%20notes.md")
        )
        XCTAssertEqual(parsed.segments, ["blob", "abc", "docs and notes.md"])
    }

    func testRejectsMalformedInput() {
        // Invalid RIDs: wrong prefix, too short, non-base58 (0, O, I, l).
        XCTAssertNil(RadSchemeHandler.parse("https://example.com"))
        XCTAssertNil(RadSchemeHandler.parse("rad:zshort"))
        XCTAssertNil(RadSchemeHandler.parse("rad:q\(String(repeating: "a", count: 30))"))
        XCTAssertNil(RadSchemeHandler.parse("rad:z000000000000000000000000"))
        // Traversal and separator tricks.
        XCTAssertNil(RadSchemeHandler.parse("rad:\(rid)/tree/../../etc"))
        XCTAssertNil(RadSchemeHandler.parse("rad:\(rid)/tree/%2e%2e/x"))
        XCTAssertNil(RadSchemeHandler.parse("rad:\(rid)/blob/abc/a%2Fb"))
        XCTAssertNil(RadSchemeHandler.parse("rad:\(rid)/tree//abc"))
        XCTAssertNil(RadSchemeHandler.parse("rad:\(rid)/tree\\abc"))
        XCTAssertNil(RadSchemeHandler.parse("rad:\(rid)/tree/%00"))
    }

    func testPageParamsClamping() {
        XCTAssertEqual(RadSchemeHandler.pageParams([:]).page, 0)
        XCTAssertEqual(RadSchemeHandler.pageParams([:]).perPage, 30)
        XCTAssertEqual(RadSchemeHandler.pageParams(["perPage": "1000"]).perPage, 100)
        XCTAssertEqual(RadSchemeHandler.pageParams(["perPage": "0"]).perPage, 1)
        XCTAssertEqual(RadSchemeHandler.pageParams(["page": "-3"]).page, 0)
        XCTAssertEqual(RadSchemeHandler.pageParams(["page": "9999999999"]).page, 1_000_000)
    }
}
