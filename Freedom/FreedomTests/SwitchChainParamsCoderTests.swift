import XCTest
@testable import Freedom

final class SwitchChainParamsCoderTests: XCTestCase {
    func testGnosisHexDecodes() throws {
        let id = try SwitchChainParamsCoder.decodeChainID(params: [["chainId": "0x64"]])
        XCTAssertEqual(id, 100)
    }

    func testMainnetHexDecodes() throws {
        let id = try SwitchChainParamsCoder.decodeChainID(params: [["chainId": "0x1"]])
        XCTAssertEqual(id, 1)
    }

    func testEmptyParamsThrows() {
        XCTAssertThrowsError(try SwitchChainParamsCoder.decodeChainID(params: []))
    }

    func testMissingChainIdThrows() {
        XCTAssertThrowsError(
            try SwitchChainParamsCoder.decodeChainID(params: [["wrongKey": "0x64"]])
        )
    }

    func testNonStringChainIdThrows() {
        XCTAssertThrowsError(
            try SwitchChainParamsCoder.decodeChainID(params: [["chainId": 100]])
        )
    }

    func testMalformedHexThrows() {
        XCTAssertThrowsError(
            try SwitchChainParamsCoder.decodeChainID(params: [["chainId": "0xZZ"]])
        )
    }
}
