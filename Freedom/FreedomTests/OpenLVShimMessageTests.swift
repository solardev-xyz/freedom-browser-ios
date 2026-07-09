import XCTest
@testable import Freedom

/// Wire contract between `OpenLVShim.js` and `WebViewOpenLVEngine` —
/// every message the shim posts through the `openlv` script-message
/// handler must parse into exactly one `OpenLVShimMessage`, and
/// anything else (malformed, unknown type, wrong field types) must be
/// dropped as `nil` rather than crash or misroute.
final class OpenLVShimMessageTests: XCTestCase {
    func testParsesReady() {
        guard case .ready = OpenLVShimMessage.parse(["type": "ready"]) else {
            return XCTFail("expected .ready")
        }
    }

    func testParsesStatusValues() {
        let cases: [(String, OpenLVEngineStatus)] = [
            ("connecting", .connecting),
            ("connected", .connected),
            ("disconnected", .disconnected),
        ]
        for (wire, expected) in cases {
            guard case .status(let status) = OpenLVShimMessage.parse(["type": "status", "status": wire]) else {
                return XCTFail("expected .status for \(wire)")
            }
            XCTAssertEqual(status, expected)
        }
    }

    func testParsesFailedStatusWithMessage() {
        let body: [String: Any] = ["type": "status", "status": "failed", "message": "broker unreachable"]
        guard case .status(.failed(let message)) = OpenLVShimMessage.parse(body) else {
            return XCTFail("expected .status(.failed)")
        }
        XCTAssertEqual(message, "broker unreachable")
    }

    func testFailedStatusWithoutMessageGetsFallbackText() {
        guard case .status(.failed(let message)) = OpenLVShimMessage.parse(["type": "status", "status": "failed"]) else {
            return XCTFail("expected .status(.failed)")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testParsesRequestWithParams() {
        let body: [String: Any] = [
            "type": "request",
            "id": 7,
            "method": "personal_sign",
            "params": ["0xdeadbeef", "0x1111111111111111111111111111111111111111"],
        ]
        guard case .request(let id, let method, let params) = OpenLVShimMessage.parse(body) else {
            return XCTFail("expected .request")
        }
        XCTAssertEqual(id, 7)
        XCTAssertEqual(method, "personal_sign")
        XCTAssertEqual(params as? [String], ["0xdeadbeef", "0x1111111111111111111111111111111111111111"])
    }

    func testRequestWithoutParamsDefaultsToEmpty() {
        let body: [String: Any] = ["type": "request", "id": 1, "method": "eth_requestAccounts"]
        guard case .request(_, _, let params) = OpenLVShimMessage.parse(body) else {
            return XCTFail("expected .request")
        }
        XCTAssertTrue(params.isEmpty)
    }

    func testRejectsMalformedBodies() {
        XCTAssertNil(OpenLVShimMessage.parse("not a dict"))
        XCTAssertNil(OpenLVShimMessage.parse(["type": "unknown"]))
        XCTAssertNil(OpenLVShimMessage.parse(["type": "status"]))                    // missing status
        XCTAssertNil(OpenLVShimMessage.parse(["type": "status", "status": "weird"]))
        XCTAssertNil(OpenLVShimMessage.parse(["type": "request", "method": "x"]))    // missing id
        XCTAssertNil(OpenLVShimMessage.parse(["type": "request", "id": 1]))          // missing method
        XCTAssertNil(OpenLVShimMessage.parse(["type": "request", "id": "1", "method": "x"])) // id wrong type
        XCTAssertNil(OpenLVShimMessage.parse([String: Any]()))
    }
}
