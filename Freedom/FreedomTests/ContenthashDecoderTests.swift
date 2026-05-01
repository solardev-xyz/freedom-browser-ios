import XCTest
@testable import Freedom

/// Test vectors are grounded in EIP-1577. Layout:
///   contenthash := <protoCode varint><value>
///   ipfs-ns  varint = e3 01     (multicodec 0xe3, high bit set → 2 bytes)
///   ipns-ns  varint = e5 01
///   swarm-ns varint = e4 01
///   value (IPFS/IPNS) = CIDv0 (bare multihash) or CIDv1 (01 + codec + mh)
///   value (Swarm)    = CIDv1-shaped: 01 + fa 01 (manifest) + 1b 20 (keccak/32)
final class ContenthashDecoderTests: XCTestCase {
    func testSwarmCodecDecodesToBzzURI() {
        // namespace `e4 01` + CIDv1 `01` + manifest `fa 01` + keccak/32 `1b 20` + 32B
        let hashHex = "c0b683a3be2593bc7e22d252a371bac921bf47d11c3f3c1680ee60e6b8ccfcc8"
        let bytes = Data([0xe4, 0x01, 0x01, 0xfa, 0x01, 0x1b, 0x20]) + Data(hex: "0x\(hashHex)")!

        let decoded = ContenthashDecoder.decode(bytes)
        XCTAssertEqual(decoded?.uri.absoluteString, "bzz://\(hashHex)")
        XCTAssertEqual(decoded?.codec, .bzz)
    }

    func testSwarmLengthMismatchReturnsNil() {
        let bytes = Data([0xe4, 0x01, 0x01, 0xfa, 0x01, 0x1b, 0x20]) + Data(repeating: 0, count: 31)
        XCTAssertNil(ContenthashDecoder.decode(bytes))
    }

    // MARK: - IPFS

    func testIPFSCanonicalCIDv1DagPbSha256DecodesToCIDv0Qm() {
        // Per EIP-1577: namespace varint `e3 01` (2 bytes) + CIDv1 `01 70` +
        // multihash `12 20` + 32-byte sha256 digest. 2+2+2+32 = 38 bytes.
        // Bytes-equivalent to CIDv0 (omits version+codec); we render as Qm…
        // for history-key compat with the older form.
        let multihash = Data([0x12, 0x20] + [UInt8](repeating: 0, count: 32))
        let bytes = Data([0xe3, 0x01, 0x01, 0x70]) + multihash

        let decoded = ContenthashDecoder.decode(bytes)
        XCTAssertEqual(decoded?.codec, .ipfs)
        XCTAssertTrue(decoded?.uri.absoluteString.hasPrefix("ipfs://Qm") ?? false,
                      "dag-pb + sha256 must produce Qm… CIDv0; got \(decoded?.uri.absoluteString ?? "nil")")
    }

    func testRealVitalikEthContenthashDecodes() {
        // Real onchain bytes captured from vitalik.eth's resolver
        // 2026-05-01. namespace `e3 01` + CIDv1 `01 70` (dag-pb) + mh `12 20`
        // + 32-byte sha256 digest. Equivalent CIDv1 form is
        // `bafybeiaql2jo3fu5b7c4lmpoi5drh5sam7yt652shwdgwbky4o7uw33u2u`.
        let hex = "e30101701220105e92ed969d0fc5c5b1ee474713f64067f13f77523d866b0558e3bf4b6f74d5"
        let bytes = Data(hex: "0x\(hex)")!

        let decoded = ContenthashDecoder.decode(bytes)
        XCTAssertEqual(decoded?.codec, .ipfs)
        XCTAssertTrue(decoded?.uri.absoluteString.hasPrefix("ipfs://Qm") ?? false,
                      "vitalik.eth's contenthash must decode; got \(decoded?.uri.absoluteString ?? "nil")")
    }

    func testIPFSCIDv1RawSha256DecodesToBafkrei() {
        // namespace `e3 01` + CIDv1 `01` + raw codec `55` + sha256-32 multihash.
        // Modern static-site ENS records frequently use the raw codec.
        let multihash = Data([0x12, 0x20] + [UInt8](repeating: 0, count: 32))
        let bytes = Data([0xe3, 0x01, 0x01, 0x55]) + multihash

        let decoded = ContenthashDecoder.decode(bytes)
        XCTAssertEqual(decoded?.codec, .ipfs)
        XCTAssertTrue(decoded?.uri.absoluteString.hasPrefix("ipfs://bafkrei") ?? false,
                      "raw + sha256 must produce bafkrei*; got \(decoded?.uri.absoluteString ?? "nil")")
    }

    func testIPFSCIDv1DagCborSha256DecodesToBafyrei() {
        // namespace `e3 01` + CIDv1 `01` + dag-cbor `71` + sha256-32 multihash.
        let multihash = Data([0x12, 0x20] + [UInt8](repeating: 0, count: 32))
        let bytes = Data([0xe3, 0x01, 0x01, 0x71]) + multihash

        let decoded = ContenthashDecoder.decode(bytes)
        XCTAssertEqual(decoded?.codec, .ipfs)
        XCTAssertTrue(decoded?.uri.absoluteString.hasPrefix("ipfs://bafyrei") ?? false,
                      "dag-cbor + sha256 must produce bafyrei*; got \(decoded?.uri.absoluteString ?? "nil")")
    }

    func testIPFSCIDv0BareMultihashDecodesToQm() {
        // Older (rare) form: namespace varint + bare multihash (no version
        // or codec — dag-pb implicit). Layout: `e3 01` + `12 20` + 32B.
        let multihash = Data([0x12, 0x20] + [UInt8](repeating: 0, count: 32))
        let bytes = Data([0xe3, 0x01]) + multihash

        let decoded = ContenthashDecoder.decode(bytes)
        XCTAssertEqual(decoded?.codec, .ipfs)
        XCTAssertTrue(decoded?.uri.absoluteString.hasPrefix("ipfs://Qm") ?? false)
    }

    func testIPFSMalformedMultihashLengthReturnsNil() {
        // CIDv1 + dag-pb + multihash declares len=32 but only 16 digest
        // bytes follow. Both legacy Qm and base32 paths must reject.
        let bytes = Data([0xe3, 0x01, 0x01, 0x70, 0x12, 0x20]) + Data(repeating: 0, count: 16)
        XCTAssertNil(ContenthashDecoder.decode(bytes))
    }

    func testIPFSEmptyValueReturnsNil() {
        // Just the namespace varint with no value bytes — caller would have
        // already short-circuited via the empty-contenthash branch in the
        // resolver, but the decoder must still return nil rather than crash.
        let bytes = Data([0xe3, 0x01])
        XCTAssertNil(ContenthashDecoder.decode(bytes))
    }

    // MARK: - IPNS

    func testIPNSCanonicalLibp2pKeyDecodesToCIDv1Base32() {
        // namespace `e5 01` + CIDv1 `01` + libp2p-key `72` + multihash `12 20` + 32B.
        // libp2p-key isn't dag-pb so we emit base32 (`bafzaa…` typically),
        // not Qm.
        let multihash = Data([0x12, 0x20] + [UInt8](repeating: 0xab, count: 32))
        let bytes = Data([0xe5, 0x01, 0x01, 0x72]) + multihash

        let decoded = ContenthashDecoder.decode(bytes)
        XCTAssertEqual(decoded?.codec, .ipns)
        XCTAssertTrue(decoded?.uri.absoluteString.hasPrefix("ipns://b") ?? false,
                      "non-dag-pb codec must produce multibase 'b' base32; got \(decoded?.uri.absoluteString ?? "nil")")
    }

    // MARK: - Negative

    func testUnsupportedCodecReturnsNil() {
        // Bitcoin-ns codec varint 0xe807 — we don't support it.
        let bytes = Data([0xe8, 0x07]) + Data(repeating: 0, count: 20)
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
