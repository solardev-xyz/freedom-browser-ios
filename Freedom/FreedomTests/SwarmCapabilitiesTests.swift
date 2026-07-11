import XCTest
@testable import Freedom

final class SwarmCapabilitiesTests: XCTestCase {
    func testDefaultLimitsMatchSWIP() {
        let limits = SwarmCapabilities.Limits.defaults
        XCTAssertEqual(limits.maxDataBytes, 10 * 1024 * 1024)
        XCTAssertEqual(limits.maxFilesBytes, 50 * 1024 * 1024)
        XCTAssertEqual(limits.maxFileCount, 100)
        XCTAssertEqual(limits.maxPathBytes, 100)
        // Protocol constant — SWIP requires advertising exactly 4096.
        XCTAssertEqual(limits.maxChunkPayloadBytes, 4096)
    }

    func testJSONShapeWhenCanPublishTrue() {
        let caps = SwarmCapabilities(canPublish: true, reason: nil, limits: .defaults)
        let dict = caps.asJSONDict
        XCTAssertEqual(dict["specVersion"] as? String, "1.0")
        XCTAssertEqual(dict["canPublish"] as? Bool, true)
        XCTAssertTrue(dict["reason"] is NSNull)
        let limits = dict["limits"] as? [String: Any]
        XCTAssertEqual(limits?["maxDataBytes"] as? Int, 10 * 1024 * 1024)
        XCTAssertEqual(limits?["maxFilesBytes"] as? Int, 50 * 1024 * 1024)
        XCTAssertEqual(limits?["maxFileCount"] as? Int, 100)
        XCTAssertEqual(limits?["maxPathBytes"] as? Int, 100)
        XCTAssertEqual(limits?["maxChunkPayloadBytes"] as? Int, 4096)
        // Desktop-parity feature-detect fields for the signing surface.
        XCTAssertEqual(
            dict["publisherIdentityModes"] as? [String],
            ["app-scoped", "bee-wallet"]
        )
        let extensions = dict["extensions"] as? [String: Any]
        XCTAssertEqual(extensions?["publisherSigning"] as? Bool, true)
    }

    func testJSONShapeWhenReasonPresent() {
        let caps = SwarmCapabilities(
            canPublish: false,
            reason: SwarmRouter.ErrorPayload.Reason.notConnected,
            limits: .defaults
        )
        let dict = caps.asJSONDict
        XCTAssertEqual(dict["canPublish"] as? Bool, false)
        XCTAssertEqual(dict["reason"] as? String, "not-connected")
    }
}
