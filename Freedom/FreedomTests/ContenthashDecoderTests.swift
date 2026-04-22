import XCTest
@testable import Freedom

final class ContenthashDecoderTests: XCTestCase {
    func testSwarmCodecDecodesToBzzURI() {
        // swarm-ns + manifest codec prefix + 32-byte hash
        let hashHex = "c0b683a3be2593bc7e22d252a371bac921bf47d11c3f3c1680ee60e6b8ccfcc8"
        let bytes = Data([0xe4, 0x01, 0x01, 0xfa, 0x01, 0x1b, 0x20]) + Data(hex: "0x\(hashHex)")!

        let decoded = ContenthashDecoder.decode(bytes)
        XCTAssertEqual(decoded?.uri.absoluteString, "bzz://\(hashHex)")
        XCTAssertEqual(decoded?.codec, .bzz)
    }

    func testIPFSCodecDecodesToCIDv0Base58() {
        // ipfs-ns prefix + multihash [sha2-256(0x12) | len=32(0x20) | 32-byte digest]
        // Test vector: all-zero digest produces a deterministic CID.
        let multihash = Data([0x12, 0x20] + [UInt8](repeating: 0, count: 32))
        let bytes = Data([0xe3, 0x01, 0x70]) + multihash

        let decoded = ContenthashDecoder.decode(bytes)
        XCTAssertEqual(decoded?.codec, .ipfs)
        XCTAssertTrue(decoded?.uri.absoluteString.hasPrefix("ipfs://Qm") ?? false,
                      "CIDv0 for sha2-256 multihash must start with Qm; got \(decoded?.uri.absoluteString ?? "nil")")
    }

    func testIPNSCodecDecodesToBase58() {
        let multihash = Data([0x12, 0x20] + [UInt8](repeating: 0xab, count: 32))
        let bytes = Data([0xe5, 0x01, 0x72]) + multihash

        let decoded = ContenthashDecoder.decode(bytes)
        XCTAssertEqual(decoded?.codec, .ipns)
        XCTAssertTrue(decoded?.uri.absoluteString.hasPrefix("ipns://") ?? false)
    }

    func testUnsupportedCodecReturnsNil() {
        // Bitcoin codec 0xe807 — we don't support it.
        let bytes = Data([0xe8, 0x07]) + Data(repeating: 0, count: 20)
        XCTAssertNil(ContenthashDecoder.decode(bytes))
    }

    func testMultihashLengthMismatchReturnsNil() {
        // Multihash declares len=32 but only 16 digest bytes follow.
        let multihash = Data([0x12, 0x20] + [UInt8](repeating: 0, count: 16))
        let bytes = Data([0xe3, 0x01, 0x70]) + multihash
        XCTAssertNil(ContenthashDecoder.decode(bytes))
    }

    func testSwarmLengthMismatchReturnsNil() {
        let bytes = Data([0xe4, 0x01, 0x01, 0xfa, 0x01, 0x1b, 0x20]) + Data(repeating: 0, count: 31)
        XCTAssertNil(ContenthashDecoder.decode(bytes))
    }
}

final class Base58Tests: XCTestCase {
    func testEmptyInputEncodesEmpty() {
        XCTAssertEqual(Base58.encode(Data()), "")
    }

    func testLeadingZeroBecomesOne() {
        XCTAssertEqual(Base58.encode(Data([0])), "1")
        XCTAssertEqual(Base58.encode(Data([0, 0, 1])), "112")
    }

    func testKnownVector() {
        // Bitcoin reference: "Hello World!" → 2NEpo7TZRRrLZSi2U
        let input = Data("Hello World!".utf8)
        XCTAssertEqual(Base58.encode(input), "2NEpo7TZRRrLZSi2U")
    }
}
