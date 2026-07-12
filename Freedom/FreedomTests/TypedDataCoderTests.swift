import XCTest
import web3
@testable import Freedom

/// Pins the semantic validation `TypedDataCoder` layers over the plain
/// JSON decode. web3.swift's `TypedData.encodeType` force-unwraps
/// `types[primaryType]!` (and `signableHash()` does the same for
/// `"EIP712Domain"`), so a payload missing either entry would crash
/// the app at sign time instead of erroring — these tests reproduce
/// the crashing payloads and assert they're rejected at decode.
final class TypedDataCoderTests: XCTestCase {
    /// Minimal valid v4 payload — Mail primary type, domain + types
    /// complete.
    private func payload(
        types: [String: Any],
        primaryType: String = "Mail",
        message: [String: Any] = ["contents": "hi"]
    ) -> [String: Any] {
        [
            "types": types,
            "primaryType": primaryType,
            "domain": ["name": "Test", "chainId": 1],
            "message": message,
        ]
    }

    private let mailType: [Any] = [["name": "contents", "type": "string"]]
    private let domainType: [Any] = [
        ["name": "name", "type": "string"],
        ["name": "chainId", "type": "uint256"],
    ]

    func testDecodesValidPayloadObjectAndString() throws {
        let object = payload(types: ["EIP712Domain": domainType, "Mail": mailType])
        let fromObject = try TypedDataCoder.decode(object)
        XCTAssertEqual(fromObject.primaryType, "Mail")

        let json = try JSONSerialization.data(withJSONObject: object)
        let fromString = try TypedDataCoder.decode(String(data: json, encoding: .utf8)!)
        XCTAssertEqual(fromString, fromObject)

        // The validated payload must actually encode — proves the
        // checks don't reject what web3.swift can sign.
        XCTAssertNoThrow(try fromObject.signableHash())
    }

    /// The crash payload from the field: dapp omitted EIP712Domain
    /// from `types`. Pre-fix this force-unwrap-crashed in
    /// `signableHash()` after the user tapped Sign.
    func testRejectsMissingEIP712DomainType() {
        let object = payload(types: ["Mail": mailType])
        XCTAssertThrowsError(try TypedDataCoder.decode(object)) { error in
            XCTAssertEqual(
                error as? TypedDataCoder.Error,
                .missingType("EIP712Domain")
            )
        }
    }

    func testRejectsUnknownPrimaryType() {
        let object = payload(
            types: ["EIP712Domain": domainType, "Mail": mailType],
            primaryType: "Order"
        )
        XCTAssertThrowsError(try TypedDataCoder.decode(object)) { error in
            XCTAssertEqual(error as? TypedDataCoder.Error, .missingType("Order"))
        }
    }

    /// EIP-712 requires a bare struct name; the array-suffixed form
    /// doesn't match a `types` key verbatim and would also crash the
    /// encoder's force-unwrap.
    func testRejectsArraySuffixedPrimaryType() {
        let object = payload(
            types: ["EIP712Domain": domainType, "Mail": mailType],
            primaryType: "Mail[]"
        )
        XCTAssertThrowsError(try TypedDataCoder.decode(object)) { error in
            XCTAssertEqual(error as? TypedDataCoder.Error, .missingType("Mail[]"))
        }
    }

    /// Undefined types referenced from struct fields stay decodable —
    /// web3.swift handles those with a thrown ABIError (no crash), and
    /// over-rejecting here would break payloads MetaMask accepts.
    func testAllowsUndefinedFieldTypesThrough() throws {
        let types: [String: Any] = [
            "EIP712Domain": domainType,
            "Mail": [["name": "from", "type": "Person"]],  // Person undefined
        ]
        // "from" must be present in the message — the encoder skips
        // absent fields entirely, and this test needs it to reach the
        // atomic-type parse of the undefined "Person".
        let typed = try TypedDataCoder.decode(payload(
            types: types, message: ["from": "0x1111111111111111111111111111111111111111"]
        ))
        XCTAssertEqual(typed.primaryType, "Mail")
        // Encoding fails with a thrown error, not a crash.
        XCTAssertThrowsError(try typed.signableHash())
    }

    func testRejectsNonJSONParam() {
        XCTAssertThrowsError(try TypedDataCoder.decode(42))
    }
}
