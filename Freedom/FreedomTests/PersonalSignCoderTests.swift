import XCTest
@testable import Freedom

final class PersonalSignCoderTests: XCTestCase {
    private let address = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"

    func testCanonicalOrderMessageThenAddress() throws {
        let decoded = try PersonalSignCoder.decode(params: ["Hello, world", address])
        XCTAssertEqual(decoded.declaredAddress, address)
        XCTAssertEqual(decoded.preview, .utf8("Hello, world"))
        XCTAssertEqual(decoded.message, Data("Hello, world".utf8))
    }

    /// Some dapps (legacy eth_sign order) send [address, message]. The
    /// coder disambiguates by shape — address is always 0x + 40 hex.
    func testReversedOrderAddressThenMessage() throws {
        let decoded = try PersonalSignCoder.decode(params: [address, "Hello"])
        XCTAssertEqual(decoded.declaredAddress, address)
        XCTAssertEqual(decoded.preview, .utf8("Hello"))
    }

    func testHexMessageDecodedAsBytes() throws {
        // "Freedom" in UTF-8 hex
        let hex = "0x46726565646f6d"
        let decoded = try PersonalSignCoder.decode(params: [hex, address])
        XCTAssertEqual(decoded.message, Data("Freedom".utf8))
        // Printable UTF-8 → preview as utf8 text, not raw hex.
        XCTAssertEqual(decoded.preview, .utf8("Freedom"))
    }

    func testHexMessageWithNonPrintableStaysHex() throws {
        // 0xDEADBEEF — not valid UTF-8 text.
        let hex = "0xdeadbeef"
        let decoded = try PersonalSignCoder.decode(params: [hex, address])
        XCTAssertEqual(decoded.message.count, 4)
        XCTAssertEqual(decoded.preview, .hex(hex))
    }

    /// SIWE ("Sign-In With Ethereum") messages contain tabs + newlines;
    /// those are printable and must not flip the preview to hex.
    func testMultilineUTF8StaysAsText() throws {
        let siwe = "example.com wants you to sign in\nURI: https://example.com"
        let decoded = try PersonalSignCoder.decode(params: [siwe, address])
        XCTAssertEqual(decoded.preview, .utf8(siwe))
    }

    func testOddLengthHexFallsBackToUTF8() throws {
        // "0xabc" has odd payload length — not valid hex, treat as literal UTF-8.
        let decoded = try PersonalSignCoder.decode(params: ["0xabc", address])
        XCTAssertEqual(decoded.preview, .utf8("0xabc"))
        XCTAssertEqual(decoded.message, Data("0xabc".utf8))
    }

    func testMissingParamsThrows() {
        XCTAssertThrowsError(try PersonalSignCoder.decode(params: []))
        XCTAssertThrowsError(try PersonalSignCoder.decode(params: ["only one"]))
        XCTAssertThrowsError(try PersonalSignCoder.decode(params: [123, "x"]))
    }

    func testTwoAddressesFallsBackToMetaMaskOrder() throws {
        // Rare: both params are 40-hex-with-0x. Fall back to [message, address].
        // The 0x1111… bytes aren't printable UTF-8 (DC1 control char), so
        // the preview stays as hex.
        let a = "0x1111111111111111111111111111111111111111"
        let b = "0x2222222222222222222222222222222222222222"
        let decoded = try PersonalSignCoder.decode(params: [a, b])
        XCTAssertEqual(decoded.declaredAddress, b)
        XCTAssertEqual(decoded.preview, .hex(a))
    }
}
