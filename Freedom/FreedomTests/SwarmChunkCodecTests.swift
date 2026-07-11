import XCTest
import web3
@testable import Freedom

/// CAC/SOC parse + validation. Round-trip vectors are built with the
/// same primitives the write path uses (`SwarmSOC` + `FeedSigner`),
/// which `SwarmSOCTests` / `FeedSignerTests` pin against bee-js — so
/// these tests verify the read path against the pinned write path
/// rather than duplicating raw byte vectors.
final class SwarmChunkCodecTests: XCTestCase {
    /// Deterministic secp256k1 key (< curve order).
    private let privateKey = Data(repeating: 0xAB, count: 32)
    private let payload = Data("hello swarm".utf8)

    private func hex(_ data: Data) -> String {
        data.web3.hexString.web3.noHexPrefix
    }

    // MARK: - CAC

    func testParseCACRoundTrip() throws {
        let cac = try SwarmSOC.makeCAC(payload: payload)
        let parsed = try SwarmChunkCodec.parseCAC(
            referenceHex: hex(cac.address),
            raw: SwarmSOC.socBody(cac: cac)
        )
        XCTAssertEqual(parsed.payload, payload)
        XCTAssertEqual(parsed.span, UInt64(payload.count))
    }

    func testParseCACAcceptsUppercaseReference() throws {
        let cac = try SwarmSOC.makeCAC(payload: payload)
        let parsed = try SwarmChunkCodec.parseCAC(
            referenceHex: hex(cac.address).uppercased(),
            raw: SwarmSOC.socBody(cac: cac)
        )
        XCTAssertEqual(parsed.payload, payload)
    }

    func testParseCACRejectsAddressMismatch() throws {
        let cac = try SwarmSOC.makeCAC(payload: payload)
        XCTAssertThrowsError(try SwarmChunkCodec.parseCAC(
            referenceHex: String(repeating: "0", count: 64),
            raw: SwarmSOC.socBody(cac: cac)
        )) { error in
            XCTAssertEqual(error as? SwarmChunkCodec.Error, .typeMismatch)
        }
    }

    func testParseCACRejectsTamperedPayload() throws {
        let cac = try SwarmSOC.makeCAC(payload: payload)
        var raw = SwarmSOC.socBody(cac: cac)
        raw[raw.count - 1] ^= 0xFF
        XCTAssertThrowsError(try SwarmChunkCodec.parseCAC(
            referenceHex: hex(cac.address), raw: raw
        ))
    }

    func testParseCACRejectsTooShortAndOversized() {
        XCTAssertThrowsError(try SwarmChunkCodec.parseCAC(
            referenceHex: String(repeating: "0", count: 64),
            raw: Data(count: 8)  // span only, no payload
        ))
        XCTAssertThrowsError(try SwarmChunkCodec.parseCAC(
            referenceHex: String(repeating: "0", count: 64),
            raw: Data(count: 8 + 4097)
        ))
    }

    // MARK: - SOC

    /// Builds a bee-wire SOC (`identifier || sig || span || payload`)
    /// exactly like the write path does.
    private func makeSOC(
        identifier: Data, payload: Data
    ) throws -> (addressHex: String, raw: Data, ownerHex: String) {
        let cac = try SwarmSOC.makeCAC(payload: payload)
        let digest = SwarmSOC.signingMessage(
            identifier: identifier, cacAddress: cac.address
        ).web3.keccak256
        let sig = try FeedSigner.sign(digest: digest, privateKey: privateKey)
        let ownerBytes = try FeedSigner.ownerAddressBytes(privateKey: privateKey)
        let address = SwarmSOC.socAddress(
            identifier: identifier, ownerAddress: ownerBytes
        )
        return (hex(address), identifier + sig + SwarmSOC.socBody(cac: cac), hex(ownerBytes))
    }

    func testParseSOCRoundTrip() throws {
        let identifier = Data(repeating: 0x42, count: 32)
        let soc = try makeSOC(identifier: identifier, payload: payload)
        let parsed = try SwarmChunkCodec.parseSOC(
            addressHex: soc.addressHex, raw: soc.raw
        )
        XCTAssertEqual(parsed.payload, payload)
        XCTAssertEqual(parsed.span, UInt64(payload.count))
        XCTAssertEqual(parsed.identifierHex, hex(identifier))
        XCTAssertEqual(parsed.signatureHex.count, 130)
        XCTAssertEqual(parsed.owner, Hex.checksummed(soc.ownerHex))
    }

    func testParseSOCRejectsWrongAddress() throws {
        let soc = try makeSOC(
            identifier: Data(repeating: 0x42, count: 32), payload: payload
        )
        XCTAssertThrowsError(try SwarmChunkCodec.parseSOC(
            addressHex: String(repeating: "0", count: 64), raw: soc.raw
        )) { error in
            XCTAssertEqual(error as? SwarmChunkCodec.Error, .typeMismatch)
        }
    }

    func testParseSOCRejectsTamperedPayload() throws {
        let soc = try makeSOC(
            identifier: Data(repeating: 0x42, count: 32), payload: payload
        )
        var raw = soc.raw
        raw[raw.count - 1] ^= 0xFF
        // Tampering the payload changes the CAC address → the recovered
        // signer changes → derived SOC address no longer matches.
        XCTAssertThrowsError(try SwarmChunkCodec.parseSOC(
            addressHex: soc.addressHex, raw: raw
        ))
    }

    func testParseSOCRejectsCACShapedBody() throws {
        // A plain CAC body is far below the SOC envelope minimum —
        // the SWIP's "CAC returned where a SOC was requested" case.
        let cac = try SwarmSOC.makeCAC(payload: payload)
        XCTAssertThrowsError(try SwarmChunkCodec.parseSOC(
            addressHex: hex(cac.address), raw: SwarmSOC.socBody(cac: cac)
        ))
    }

    // MARK: - Span helpers

    func testSpanBytesRoundTrip() {
        for value: UInt64 in [0, 1, 4096, 0xDEAD_BEEF, .max] {
            XCTAssertEqual(
                SwarmChunkCodec.spanValue(SwarmChunkCodec.spanBytes(value)),
                value
            )
        }
    }

    func testSpanBytesLittleEndian() {
        // Bee's span convention is LE (unlike the BE feed index).
        XCTAssertEqual(
            SwarmChunkCodec.spanBytes(1),
            Data([1, 0, 0, 0, 0, 0, 0, 0])
        )
    }

    func testSpanJSONSafeIntegerBoundary() {
        XCTAssertEqual(SwarmChunkCodec.spanJSON(4096) as? Int, 4096)
        XCTAssertEqual(
            SwarmChunkCodec.spanJSON(SwarmChunkCodec.maxSafeJSInteger) as? Int,
            9_007_199_254_740_991
        )
        // Above 2^53-1 the bridge carries a decimal string; the JS
        // preload converts to BigInt.
        XCTAssertEqual(
            SwarmChunkCodec.spanJSON(SwarmChunkCodec.maxSafeJSInteger + 1) as? String,
            "9007199254740992"
        )
    }
}
