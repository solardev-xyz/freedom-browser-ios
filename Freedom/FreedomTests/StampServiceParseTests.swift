import XCTest
@testable import Freedom

/// `/stamps` rows as ant returns them, including the v0.5.52
/// `propagating` flag for a batch inside its post-buy window.
@MainActor
final class StampServiceParseTests: XCTestCase {
    private func row(usable: Bool, propagating: Bool?) -> [String: Any] {
        var raw: [String: Any] = [
            "batchID": String(repeating: "ab", count: 32), "depth": 21, "bucketDepth": 16,
            "utilization": 4, "usable": usable, "amount": "4142000000", "batchTTL": 86_400, "immutableFlag": true,
        ]
        if let propagating { raw["propagating"] = propagating }
        return raw
    }

    func testPropagatingDefaultsToFalseWhenAbsent() throws {
        let batch = try XCTUnwrap(StampService.parseBatch(row(usable: false, propagating: nil)))
        XCTAssertFalse(batch.usable)
        XCTAssertFalse(batch.propagating)
        XCTAssertFalse(batch.isMutable)
        XCTAssertEqual(batch.depth, 21)
    }

    func testPropagatingIsCarriedThrough() throws {
        let confirming = try XCTUnwrap(StampService.parseBatch(row(usable: false, propagating: true)))
        XCTAssertTrue(confirming.propagating)
        let usable = try XCTUnwrap(StampService.parseBatch(row(usable: true, propagating: false)))
        XCTAssertTrue(usable.usable)
        XCTAssertFalse(usable.propagating)
    }

    func testMissingRequiredFieldDropsTheRow() {
        var raw = row(usable: true, propagating: nil)
        raw.removeValue(forKey: "usable")
        XCTAssertNil(StampService.parseBatch(raw))
    }
}
