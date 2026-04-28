import XCTest
@testable import Freedom

/// Pins iOS SOC primitives byte-for-byte against bee-js. Vectors captured
/// from `freedom-browser/node_modules/@ethersphere/bee-js`'s
/// `cafe-utility.Binary.{keccak256, log2Reduce, partition, concatBytes}`
/// driving the same formulas bee-js's internal modules use. A future
/// iOS-side keccak / BMT refactor can't silently drift away from
/// desktop without breaking these tests.
final class SwarmSOCTests: XCTestCase {
    // MARK: - feedIdentifier

    /// Vectors: 3 topics (canonical fixture topic, all-0xaa, all-zero) ×
    /// 5 indices (0, 1, 42, 2¹⁶-1, 2³²-1). Captures the bee-js
    /// `keccak256(topic || indexBE)` formula across the indexing range
    /// dapps will hit.
    func testFeedIdentifierMatchesBeeJSFixture() {
        let cases: [(topic: String, index: UInt64, identifier: String)] = [
            ("f757932a4cab2ba386df56c48cff6abd0515ed9e4ca464d44facb942bf1790b5", 0,
             "ad1043721a8277e6f91f5ce59ee34dfb15ed1439db7f9ec2886731657ef9a74c"),
            ("f757932a4cab2ba386df56c48cff6abd0515ed9e4ca464d44facb942bf1790b5", 1,
             "b3fc50019aae7a30f129abbcd35c4856fa13d8a3adc5345be2e583cddcfa494a"),
            ("f757932a4cab2ba386df56c48cff6abd0515ed9e4ca464d44facb942bf1790b5", 42,
             "7ccde3b72c22a62e14cec01afd2ec75731f29b43fda9c0ca4b2523e87879306f"),
            ("f757932a4cab2ba386df56c48cff6abd0515ed9e4ca464d44facb942bf1790b5", 65535,
             "cbca7ad1e237b0575b68371de92b32fdf6c6268fbe5b98eb9edd40d700039d47"),
            ("f757932a4cab2ba386df56c48cff6abd0515ed9e4ca464d44facb942bf1790b5", 4_294_967_295,
             "853d443e3faa69248d0f0914b05dc569cfa8ed3fc3fe99e612edcaa45ef6f1a0"),
            (String(repeating: "aa", count: 32), 0,
             "5a233843ec4d7c91e238a5cd1304f014219085405d84f0e8080cc896b7f5b6dc"),
            (String(repeating: "aa", count: 32), 1,
             "20c11bf28d8e794b13a5fe1e4715556ae4ac69da83d10cb73a27b5f2250bebe5"),
            (String(repeating: "aa", count: 32), 42,
             "1d32924566a1fd4edd493577d8578305d20345ba3d98a58d7e100fdffda1be45"),
            (String(repeating: "aa", count: 32), 65535,
             "c8571c43ca887c50d3352fe2fd869a54ef3c48e9425aee6eb68e10431993d585"),
            (String(repeating: "aa", count: 32), 4_294_967_295,
             "a6c215993b727c7725de61bac30a7d4e7ecf272610764da1b08bb17edbfee77b"),
            (String(repeating: "00", count: 32), 0,
             "daa77426c30c02a43d9fba4e841a6556c524d47030762eb14dc4af897e605d9b"),
            (String(repeating: "00", count: 32), 1,
             "1cf395c0cd58ef248dc39cbdb14948280ffdfcc9ac3aedbd8cb5d1d4bb9997be"),
            (String(repeating: "00", count: 32), 42,
             "42c3e073a91944dd4b8a31a1ff228e49097013c6567183d0bbf37109ed336d3e"),
            (String(repeating: "00", count: 32), 65535,
             "7025d9ab3738c22754d7bdd6510ac7c8b7d15c5db8fefa971e3661a9f7c84ba0"),
            (String(repeating: "00", count: 32), 4_294_967_295,
             "cd6adfa685cf671cd4571f84b852a1e2e3877100da966960c8d3740f31cdb8a2"),
        ]
        for testCase in cases {
            let actual = SwarmSOC.feedIdentifier(
                topic: Data(hex: testCase.topic)!, index: testCase.index
            )
            XCTAssertEqual(
                actual.hexString, testCase.identifier,
                "drift at (topic=\(testCase.topic), index=\(testCase.index))"
            )
        }
    }

    // MARK: - CAC + BMT

    /// Vectors cover the meaningful payload-size axes: 1 byte, exactly
    /// 32 (one BMT segment), 33 (just past the segment boundary), 4095
    /// (max - 1, all-but-last leaf gets payload), and 4096 (every leaf
    /// gets payload, no zero padding). The 4095 case exercises the
    /// zero-pad path on a single trailing byte; the 4096 case is the
    /// all-non-zero baseline.
    func testCACAddressMatchesBeeJSFixture() throws {
        let cases: [(payloadHex: String, span: String, address: String)] = [
            ("00", "0100000000000000",
             "fe60ba40b87599ddfb9e8947c1c872a4a1a5b56f7d1b80f0a646005b38db52a5"),
            ("aa", "0100000000000000",
             "8e420243e6112a2221fb4ae9a750c8083b16efeb014316bbbc1a6442728d749e"),
            ("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
             "2000000000000000",
             "815ee9eaca26f06a5d6f6eca88b017e99470e10afea2a60c3f254a53fca52034"),
            (String(repeating: "aa", count: 33), "2100000000000000",
             "9d2e6c08c6f3cd675cac9fdf98db7b316b7331369ca2145440eae1c9f9a26964"),
            // 64 bytes = exactly two BMT segments — locks the reduction
            // past its first iteration on a fully-populated bottom row.
            (String(repeating: "bb", count: 64), "4000000000000000",
             "7ed3c89bb1a550ccde170343ef5ac1f687be419b53b5d5c6c018c7b13186e758"),
            (String(repeating: "cd", count: 4095), "ff0f000000000000",
             "5fca91d10afa77a8d4bab9731dc36bbc920a3a0902c7946eb9b6b0d4bbf9b25b"),
            (String(repeating: "ef", count: 4096), "0010000000000000",
             "f84b10fe9ad559cd73fe651a0521aa925d794a8affb8696bb02324bc78c5bcc6"),
        ]
        for testCase in cases {
            let payload = Data(hex: testCase.payloadHex)!
            let cac = try SwarmSOC.makeCAC(payload: payload)
            XCTAssertEqual(cac.span.hexString, testCase.span,
                           "span drift at length \(payload.count)")
            XCTAssertEqual(cac.address.hexString, testCase.address,
                           "address drift at length \(payload.count)")
        }
    }

    func testCACRejectsEmptyPayload() {
        XCTAssertThrowsError(try SwarmSOC.makeCAC(payload: Data())) { error in
            XCTAssertEqual(error as? SwarmSOC.Error, .payloadEmpty)
        }
    }

    func testCACRejectsOversizedPayload() {
        let oversized = Data(repeating: 0xaa, count: 4097)
        XCTAssertThrowsError(try SwarmSOC.makeCAC(payload: oversized)) { error in
            XCTAssertEqual(error as? SwarmSOC.Error, .payloadTooLarge)
        }
    }

    // MARK: - SOC address

    /// `keccak256(identifier_32 || ownerAddress_20)`. Owner address
    /// `0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a` is the address
    /// derived from test private key `0x11..11` — kept stable across
    /// the WP6 test bring-up so other test files (`FeedSignerTests`)
    /// can reference the same identity.
    func testSOCAddressMatchesBeeJSFixture() {
        let owner = Data(hex: "19e7e376e7c213b7e7e7e46cc70a5dd086daff2a")!
        let cases: [(identifier: String, socAddress: String)] = [
            ("ad1043721a8277e6f91f5ce59ee34dfb15ed1439db7f9ec2886731657ef9a74c",
             "752edabe6e3e38eeb8ce973cdb20649ea912494addc19a3c18e84c59f04203f2"),
            ("b3fc50019aae7a30f129abbcd35c4856fa13d8a3adc5345be2e583cddcfa494a",
             "5960576fd6e06545b3723319a538d6529d4b8ce7cbc13bc3d266937d0ec226e0"),
            ("7ccde3b72c22a62e14cec01afd2ec75731f29b43fda9c0ca4b2523e87879306f",
             "2b7432331e80b75f326cbc02e198879c0478000d1c8b38d39d1f70ab46f6f76a"),
            ("cbca7ad1e237b0575b68371de92b32fdf6c6268fbe5b98eb9edd40d700039d47",
             "b5e1806046f8daf1650fe334570105174bb9a6dba187e8818ae30166dc780739"),
        ]
        for testCase in cases {
            let actual = SwarmSOC.socAddress(
                identifier: Data(hex: testCase.identifier)!, ownerAddress: owner
            )
            XCTAssertEqual(actual.hexString, testCase.socAddress,
                           "drift at identifier \(testCase.identifier)")
        }
    }

    // MARK: - Composition

    func testSOCBodyIsSpanThenPayload() throws {
        let cac = try SwarmSOC.makeCAC(payload: Data([0x01, 0x02, 0x03]))
        let body = SwarmSOC.socBody(cac: cac)
        XCTAssertEqual(body.count, 8 + 3)
        XCTAssertEqual(body.prefix(8), cac.span)
        XCTAssertEqual(body.suffix(3), Data([0x01, 0x02, 0x03]))
    }

    func testSigningMessageIsIdentifierThenCACAddress() {
        let identifier = Data(repeating: 0x11, count: 32)
        let cacAddress = Data(repeating: 0x22, count: 32)
        let message = SwarmSOC.signingMessage(
            identifier: identifier, cacAddress: cacAddress
        )
        XCTAssertEqual(message.count, 64)
        XCTAssertEqual(message.prefix(32), identifier)
        XCTAssertEqual(message.suffix(32), cacAddress)
    }
}
