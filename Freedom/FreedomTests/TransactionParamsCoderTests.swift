import BigInt
import XCTest
import web3
@testable import Freedom

final class TransactionParamsCoderTests: XCTestCase {
    private let from = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
    private let to = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"

    private func tx(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var base: [String: Any] = ["from": from, "to": to]
        for (k, v) in overrides { base[k] = v }
        return base
    }

    // MARK: - Required fields

    func testFullParamsRoundTrip() throws {
        let decoded = try TransactionParamsCoder.decode(params: [tx([
            "value": "0xde0b6b3a7640000",   // 1 ether/xDAI
            "data": "0xa9059cbb000000000000000000000000aaaa",
            "gas": "0x5208",
            "gasPrice": "0x77359400",
            "nonce": "0x5",
            "chainId": "0x64",
        ])])
        XCTAssertEqual(decoded.from.asString().lowercased(), from)
        XCTAssertEqual(decoded.to.asString().lowercased(), to)
        XCTAssertEqual(decoded.valueWei, BigUInt("de0b6b3a7640000", radix: 16))
        XCTAssertEqual(decoded.data.web3.hexString.lowercased(),
                       "0xa9059cbb000000000000000000000000aaaa")
        XCTAssertEqual(decoded.gasLimit, BigUInt(0x5208))
        XCTAssertEqual(decoded.gasPriceWei, BigUInt(0x77359400))
        XCTAssertEqual(decoded.nonce, 5)
        XCTAssertEqual(decoded.chainID, 100)
    }

    func testMinimalParamsDefaultsApplied() throws {
        let decoded = try TransactionParamsCoder.decode(params: [tx()])
        XCTAssertEqual(decoded.valueWei, 0)
        XCTAssertEqual(decoded.data, Data())
        XCTAssertNil(decoded.gasLimit)
        XCTAssertNil(decoded.gasPriceWei)
        XCTAssertNil(decoded.nonce)
        XCTAssertNil(decoded.chainID)
    }

    func testEmptyDataNormalisedToEmpty() throws {
        // Both "" and "0x" should normalise to empty Data — gas estimate
        // path treats those identically.
        XCTAssertEqual(try TransactionParamsCoder.decode(params: [tx(["data": "0x"])]).data, Data())
        XCTAssertEqual(try TransactionParamsCoder.decode(params: [tx(["data": ""])]).data, Data())
    }

    // MARK: - Errors

    func testMissingFromThrows() {
        let params = [["to": to]]
        XCTAssertThrowsError(try TransactionParamsCoder.decode(params: params)) { error in
            guard case TransactionParamsCoder.Error.missingFrom = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testMissingToThrows() {
        let params = [["from": from]]
        XCTAssertThrowsError(try TransactionParamsCoder.decode(params: params)) { error in
            guard case TransactionParamsCoder.Error.missingTo = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testBadAddressShapeThrows() {
        XCTAssertThrowsError(try TransactionParamsCoder.decode(params: [tx(["from": "not-an-address"])]))
        XCTAssertThrowsError(try TransactionParamsCoder.decode(params: [tx(["to": "0xabc"])]))
    }

    func testInvalidHexValueThrows() {
        XCTAssertThrowsError(try TransactionParamsCoder.decode(params: [tx(["value": "xyz"])])) { error in
            guard case TransactionParamsCoder.Error.invalidHex(let field, _) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(field, "value")
        }
    }

    func testEmptyParamsArrayThrows() {
        XCTAssertThrowsError(try TransactionParamsCoder.decode(params: []))
    }
}
