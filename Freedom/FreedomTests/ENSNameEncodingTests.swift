import XCTest
import ENSNormalize
@testable import Freedom

final class ENSNameEncodingTests: XCTestCase {
    // MARK: - dnsEncode

    func testDnsEncodeRootIsSingleZero() throws {
        XCTAssertEqual(try ENSNameEncoding.dnsEncode(""), Data([0]))
    }

    func testDnsEncodeSingleLabel() throws {
        // "eth" → 03 e t h 00
        XCTAssertEqual(
            try ENSNameEncoding.dnsEncode("eth"),
            Data([0x03, 0x65, 0x74, 0x68, 0x00])
        )
    }

    func testDnsEncodeMultiLabel() throws {
        // "foo.eth" → 03 f o o 03 e t h 00
        XCTAssertEqual(
            try ENSNameEncoding.dnsEncode("foo.eth"),
            Data([0x03, 0x66, 0x6f, 0x6f, 0x03, 0x65, 0x74, 0x68, 0x00])
        )
    }

    func testDnsEncodeEmptyLabelThrows() {
        XCTAssertThrowsError(try ENSNameEncoding.dnsEncode("foo..eth"))
    }

    func testDnsEncodeOverlongLabelThrows() {
        let label = String(repeating: "a", count: 64)  // one over 63
        XCTAssertThrowsError(try ENSNameEncoding.dnsEncode("\(label).eth"))
    }

    // MARK: - namehash

    func testNamehashEmptyIsAllZeros() {
        XCTAssertEqual(ENSNameEncoding.namehash(""), Data(repeating: 0, count: 32))
    }

    func testNamehashEthKnownVector() {
        // Canonical ENSIP-1 reference value for "eth".
        let expected = "93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae"
        let actual = ENSNameEncoding.namehash("eth").map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(actual, expected)
    }

    func testNamehashFooEthKnownVector() {
        // ethers.js reference: namehash("foo.eth").
        let expected = "de9b09fd7c5f901e23a3f19fecc54828e9c848539801e86591bd9801b019f84f"
        let actual = ENSNameEncoding.namehash("foo.eth").map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(actual, expected)
    }

    // MARK: - ENSIP-15 normalization (adraffy integration)

    func testNormalizationLowercasesAscii() throws {
        XCTAssertEqual(try "VITALIK.ETH".ensNormalized(), "vitalik.eth")
    }

    func testNormalizationStripsEmojiVariationSelectors() throws {
        // The adraffy port drops default variation selectors and ZWJ for
        // single-code-point emoji to produce the canonical form.
        let input = "1\u{FE0F}\u{20E3}.eth"  // keycap-1 with variation selectors
        let normalized = try input.ensNormalized()
        XCTAssertTrue(normalized.hasSuffix(".eth"))
    }

    func testNormalizationRejectsDoubleDot() {
        XCTAssertThrowsError(try "foo..eth".ensNormalized())
    }

    func testNormalizationRejectsUnderscoreInMiddle() {
        // ENSIP-15 forbids underscore except as a leading character.
        XCTAssertThrowsError(try "foo_bar.eth".ensNormalized())
    }

    func testNormalizationAcceptsEmojiLabel() throws {
        // Basic smiley emoji — should pass normalization.
        XCTAssertNoThrow(try "🙂.eth".ensNormalized())
    }

    func testNormalizationIsIdempotent() throws {
        let once = try "RaFFy🚴‍♂️.eTh".ensNormalized()
        let twice = try once.ensNormalized()
        XCTAssertEqual(once, twice)
    }
}
