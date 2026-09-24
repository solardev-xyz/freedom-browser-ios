import XCTest
import MyotisKit
@testable import Freedom

/// Host seed pins: parsing, the per-start subset, the bundled lists.
final class MyotisSeedPinsTests: XCTestCase {
    private static let key = String(repeating: "ab", count: 64)
    private static func enode(_ addr: String) -> String { "enode://\(key)@\(addr)" }

    /// Deterministic generator so the shuffle is testable.
    private struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    func testParseKeepsWellFormedEntriesAndDropsTheRest() {
        let json = """
        ["\(Self.enode("1.2.3.4:30303"))",
         "\(Self.enode("1.2.3.4:30303"))",
         "enode://\(Self.key)@node.example.com:30303",
         "enode://abc@5.6.7.8:30303",
         "\(Self.enode("[::1]:30303"))",
         "not an enode",
         "\(Self.enode("9.9.9.9:1"))"]
        """
        let parsed = MyotisSeedPins.parse(Data(json.utf8))
        XCTAssertEqual(parsed, [Self.enode("1.2.3.4:30303"), Self.enode("9.9.9.9:1")])
    }

    func testParseCapsAtTheEngineLimit() {
        let many = (0..<80).map { Self.enode("10.0.0.\($0 % 250):\(30000 + $0)") }
        let data = try! JSONSerialization.data(withJSONObject: many)
        XCTAssertEqual(MyotisSeedPins.parse(data).count, MyotisSeedPins.engineCap)
    }

    func testGarbageIsEmpty() {
        XCTAssertEqual(MyotisSeedPins.parse(Data("{}".utf8)), [])
        XCTAssertEqual(MyotisSeedPins.parse(Data("nope".utf8)), [])
        XCTAssertEqual(MyotisSeedPins.load(nil), [])
    }

    func testSelectTrimsAndShufflesWithoutInventing() {
        let all = (0..<30).map { Self.enode("10.0.0.\($0):30303") }
        var rng = LCG(state: 42)
        let picked = MyotisSeedPins.select(all, using: &rng)
        XCTAssertEqual(picked.count, MyotisSeedPins.limit)
        XCTAssertEqual(Set(picked).count, picked.count)
        XCTAssertTrue(Set(picked).isSubset(of: Set(all)))
        XCTAssertNotEqual(picked, Array(all.prefix(MyotisSeedPins.limit)), "the subset is shuffled")
        var rng2 = LCG(state: 42)
        XCTAssertEqual(MyotisSeedPins.select(all, using: &rng2), picked, "deterministic for a seeded generator")
        XCTAssertEqual(MyotisSeedPins.select(Array(all.prefix(5))).count, 5)
        XCTAssertEqual(MyotisSeedPins.select([]), [])
    }

    func testEngineJSONRoundTrips() {
        let list = [Self.enode("1.2.3.4:30303")]
        XCTAssertEqual(MyotisSeedPins.parse(Data(MyotisSeedPins.json(list).utf8)), list)
    }

    func testBundledListsAreUsable() {
        for network in ["mainnet", "gnosis"] {
            let url = Bundle.main.url(forResource: "seeds-\(network)", withExtension: "json")
            XCTAssertNotNil(url, "\(network) seed list is bundled")
            let list = MyotisSeedPins.load(url)
            XCTAssertGreaterThanOrEqual(list.count, 5, "\(network): enough pins for a cold-start floor")
            XCTAssertLessThanOrEqual(list.count, MyotisSeedPins.engineCap)
            // Every bundled entry survives the parser unchanged: a malformed
            // line in the resource would be silently dropped at runtime.
            let raw = try! JSONSerialization.jsonObject(with: Data(contentsOf: url!)) as! [String]
            XCTAssertEqual(raw, list, "\(network): bundled entries are all well-formed and unique")
        }
    }
}
