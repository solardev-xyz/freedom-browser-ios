import XCTest
@testable import Freedom

@MainActor
final class TagOwnershipTests: XCTestCase {
    func testEmptyMapReturnsNilForUnknownTag() async {
        let map = TagOwnership()
        XCTAssertNil(map.owner(of: 1))
    }

    func testRecordedTagReturnsItsOrigin() async {
        let map = TagOwnership()
        map.record(tag: 5, origin: "ens://foo.eth")
        XCTAssertEqual(map.owner(of: 5), "ens://foo.eth")
    }

    func testOwnerLookupIsCaseSensitive() async {
        // OriginIdentity normalizes case before reaching us, so casing
        // here would already be canonical. The map does no extra
        // normalization — drives that contract. The cross-origin
        // defense itself is bridge-level, smoke-tested.
        let map = TagOwnership()
        map.record(tag: 1, origin: "ens://foo.eth")
        XCTAssertEqual(map.owner(of: 1), "ens://foo.eth")
        XCTAssertNotEqual(map.owner(of: 1), "ens://FOO.eth")
    }

    func testForgetDropsTag() async {
        let map = TagOwnership()
        map.record(tag: 5, origin: "ens://foo.eth")
        map.forget(tag: 5)
        XCTAssertNil(map.owner(of: 5))
    }

    func testForgetOfUnknownTagIsNoOp() async {
        let map = TagOwnership()
        map.forget(tag: 999)  // does not crash
        XCTAssertNil(map.owner(of: 999))
    }

    func testRecordOverwritesPriorOrigin() async {
        // Bee tag UIDs are unique per session in practice, but the
        // data structure permits overwrite — last-write-wins.
        let map = TagOwnership()
        map.record(tag: 5, origin: "ens://foo.eth")
        map.record(tag: 5, origin: "ens://bar.eth")
        XCTAssertEqual(map.owner(of: 5), "ens://bar.eth")
    }

    func testIndependentTagsAreIndependentlyAddressable() async {
        let map = TagOwnership()
        map.record(tag: 1, origin: "ens://foo.eth")
        map.record(tag: 2, origin: "ens://bar.eth")
        XCTAssertEqual(map.owner(of: 1), "ens://foo.eth")
        XCTAssertEqual(map.owner(of: 2), "ens://bar.eth")
        map.forget(tag: 1)
        XCTAssertNil(map.owner(of: 1))
        XCTAssertEqual(map.owner(of: 2), "ens://bar.eth")
    }
}
