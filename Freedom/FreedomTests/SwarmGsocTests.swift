import XCTest
import web3
@testable import Freedom

/// Pins the Freedom-profile GSOC derivation against vectors captured
/// from desktop's actual dependency (`@ethersphere/bee-js@12.2.x`
/// `gsocMine`, proximity 12, context `"freedom-gsoc-v1:"`). Any drift
/// here silently breaks room-address compatibility between iOS and
/// desktop — same topic, different address, no error anywhere.
final class SwarmGsocTests: XCTestCase {
    /// Captured by running bee-js `gsocMine` with desktop's exact
    /// derivation (identifier = keccak(topic), target =
    /// keccak("freedom-gsoc-v1:" + topic)).
    private let vectors: [(topic: String, identifier: String, privateKey: String, address: String)] = [
        (
            "room:doc-42",
            "5aaa9322a34420597442f65b3f3ef3e5aba895e844f77e53cf92f20d709b26c5",
            "0000000000000000000000000000000000000000000000000000000000001118",
            "457d444476f6de5d990d9465662d55462efd4be2ef34303bf922cedc7d89b1a9"
        ),
        (
            "swarm-kit:chat-bus/v1:lobby",
            "78fd71b2243adaa64da725e768b231206e244df9f478212bcfb5c7583a3fe56a",
            "00000000000000000000000000000000000000000000000000000000000039f3",
            "74b6f12ccb5adc7e7f4d3ea6aa189aaa08977fb2dff8bd6562cab4ebd75a72c4"
        ),
        (
            "t",
            "cac1bb71f0a97c8ac94ca9546b43178a9ad254c7b757ac07433aa6df35cd8089",
            "000000000000000000000000000000000000000000000000000000000000200d",
            "8df0bf3a90c2366465f60ed6ce24451f697d6c611517476ba02ea7cdaf0dab56"
        ),
    ]

    func testDerivationMatchesBeeJsVectors() throws {
        for vector in vectors {
            let derivation = try SwarmGsoc.derive(topic: vector.topic)
            XCTAssertEqual(
                derivation.identifier.web3.hexString.web3.noHexPrefix,
                vector.identifier, "identifier for \(vector.topic)"
            )
            XCTAssertEqual(
                derivation.privateKey.web3.hexString.web3.noHexPrefix,
                vector.privateKey, "mined key for \(vector.topic)"
            )
            XCTAssertEqual(
                derivation.addressHex, vector.address,
                "address for \(vector.topic)"
            )
        }
    }

    /// The mined address must actually satisfy the placement rule the
    /// mining loop enforces — and the mined key's owner must re-derive
    /// the address through the SOC-write path (`FeedSigner`), proving
    /// subscribe (KeyUtil-derived) and send (FeedSigner-signed) agree.
    func testMinedKeySatisfiesProximityAndSocPathAgreement() throws {
        let derivation = try SwarmGsoc.derive(topic: "agreement-check")
        let target = Data("freedom-gsoc-v1:agreement-check".utf8).web3.keccak256
        guard let address = Data(hex: derivation.addressHex) else {
            return XCTFail("address not hex")
        }
        XCTAssertGreaterThanOrEqual(
            SwarmGsoc.proximityBits(address, target),
            SwarmGsoc.requiredProximityBits
        )
        let owner = try FeedSigner.ownerAddressBytes(privateKey: derivation.privateKey)
        XCTAssertEqual(
            SwarmSOC.socAddress(identifier: derivation.identifier, ownerAddress: owner)
                .web3.hexString.web3.noHexPrefix,
            derivation.addressHex
        )
    }

    func testProximityBits() {
        let zeros = Data(repeating: 0x00, count: 32)
        XCTAssertEqual(SwarmGsoc.proximityBits(zeros, zeros), 256)
        var flipLast = zeros
        flipLast[31] = 0x01
        XCTAssertEqual(SwarmGsoc.proximityBits(zeros, flipLast), 255)
        var flipFirst = zeros
        flipFirst[0] = 0x80
        XCTAssertEqual(SwarmGsoc.proximityBits(zeros, flipFirst), 0)
        var mid = zeros
        mid[1] = 0x10  // first difference at bit 11
        XCTAssertEqual(SwarmGsoc.proximityBits(zeros, mid), 11)
    }
}
