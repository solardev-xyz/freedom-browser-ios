import XCTest
import web3
@testable import Freedom

final class CCIPResolverTests: XCTestCase {

    // MARK: Parse

    /// Round-trip: encode a known OffchainLookup as a revert payload using
    /// web3.swift's public ABIRevertError.encode → ABIFunctionEncoder, then
    /// feed the bytes through our parser. Guards that our decode path stays
    /// aligned with the library's encode path even if it evolves.
    func testParseOffchainLookupRoundTrip() throws {
        let original = OffchainLookup(
            address: EthereumAddress("0xDE0B295669A9FD93d5F28D9Ec85E40f4cb697BAe"),
            urls: ["https://gateway.example/{sender}/{data}.json", "https://fallback.example/lookup"],
            callData: Data([0xaa, 0xbb, 0xcc, 0xdd]),
            callbackFunction: Data([0x11, 0x22, 0x33, 0x44]),
            extraData: Data([0xde, 0xad, 0xbe, 0xef])
        )
        let encoder = ABIFunctionEncoder(OffchainLookup.name)
        try original.encode(to: encoder)
        let encoded = try encoder.encoded()  // selector + args

        let parsed = try CCIPResolver.parseOffchainLookup(data: encoded)
        XCTAssertEqual(parsed.address, original.address)
        XCTAssertEqual(parsed.urls, original.urls)
        XCTAssertEqual(parsed.callData, original.callData)
        XCTAssertEqual(parsed.callbackFunction, original.callbackFunction)
        XCTAssertEqual(parsed.extraData, original.extraData)
    }

    func testParseRejectsWrongSelector() {
        let junk = Data([0xfa, 0xce, 0xfe, 0xed, 0x00, 0x00])
        XCTAssertThrowsError(try CCIPResolver.parseOffchainLookup(data: junk))
    }

    // MARK: Callback encoding

    /// encodeCallback should produce callbackFunction(4) || abi.encode(bytes,bytes).
    /// We verify by decoding the tail — ABIDecoder.decodeData round-trips the
    /// two `bytes` values faithfully.
    func testEncodeCallbackDecodesBackToInputs() throws {
        let lookup = OffchainLookup(
            address: .zero,
            urls: [],
            callData: Data(),
            callbackFunction: Data([0xde, 0xad, 0xbe, 0xef]),
            extraData: Data([0x01, 0x02, 0x03])
        )
        let gateway = Data([0x55, 0x66, 0x77, 0x88, 0x99, 0xaa])
        let encoded = CCIPResolver.encodeCallback(lookup: lookup, gatewayResponse: gateway)

        XCTAssertEqual(encoded.prefix(4), Data([0xde, 0xad, 0xbe, 0xef]))
        let tail = encoded.dropFirst(4).web3.hexString
        let decoded = try ABIDecoder.decodeData(tail, types: [Data.self, Data.self])
        let decodedGateway: Data = try decoded[0].decoded()
        let decodedExtra: Data = try decoded[1].decoded()
        XCTAssertEqual(decodedGateway, gateway)
        XCTAssertEqual(decodedExtra, lookup.extraData)
    }

    // MARK: Request building

    func testBuildRequestUsesGETWhenDataTemplatePresent() {
        let req = CCIPResolver.buildRequest(
            template: "https://gw.example/{sender}/{data}.json",
            sender: "0xabc", callData: "0x1234"
        )
        XCTAssertEqual(req?.method, "GET")
        XCTAssertNil(req?.body)
        XCTAssertEqual(req?.url.absoluteString, "https://gw.example/0xabc/0x1234.json")
    }

    func testBuildRequestUsesPOSTWithoutDataTemplate() throws {
        let req = CCIPResolver.buildRequest(
            template: "https://gw.example/lookup",
            sender: "0xabc", callData: "0x1234"
        )
        XCTAssertEqual(req?.method, "POST")
        XCTAssertEqual(req?.url.absoluteString, "https://gw.example/lookup")
        let body = try XCTUnwrap(req?.body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: String]
        XCTAssertEqual(json?["sender"], "0xabc")
        XCTAssertEqual(json?["data"], "0x1234")
    }

    func testBuildRequestSubstitutesSenderOnPOST() {
        let req = CCIPResolver.buildRequest(
            template: "https://gw.example/{sender}/resolve",
            sender: "0xdeadbeef", callData: "0xff"
        )
        XCTAssertEqual(req?.url.absoluteString, "https://gw.example/0xdeadbeef/resolve")
    }

    func testBuildRequestRejectsInvalidURL() {
        XCTAssertNil(CCIPResolver.buildRequest(
            template: "http ://broken\n\nnot a url",
            sender: "x", callData: "y"
        ))
    }

    // MARK: Gateway body parsing

    func testParseGatewayBodyAcceptsHexString() throws {
        let body = try JSONSerialization.data(withJSONObject: ["data": "0xdeadbeef"])
        XCTAssertEqual(CCIPResolver.parseGatewayBody(body), Data([0xde, 0xad, 0xbe, 0xef]))
    }

    func testParseGatewayBodyRejectsMissingData() throws {
        let body = try JSONSerialization.data(withJSONObject: ["result": "0xdeadbeef"])
        XCTAssertNil(CCIPResolver.parseGatewayBody(body))
    }

    func testParseGatewayBodyRejectsNonJSON() {
        XCTAssertNil(CCIPResolver.parseGatewayBody(Data("not json".utf8)))
    }

    // MARK: Full resolve() flow

    /// Encode a sample OffchainLookup revert, run resolve() with a mock that
    /// returns a verifiable gateway body on first URL and a successful
    /// eth_call response, assert final hex matches.
    func testResolveHappyPathSingleGateway() async throws {
        let lookup = OffchainLookup(
            address: EthereumAddress("0xDE0B295669A9FD93d5F28D9Ec85E40f4cb697BAe"),
            urls: ["https://gw.example/lookup"],
            callData: Data([0xaa]),
            callbackFunction: Data([0x11, 0x22, 0x33, 0x44]),
            extraData: Data([0xde, 0xad])
        )
        let revert = try encodedRevert(lookup: lookup)

        let gatewayHex = "0x112233"
        let finalHex = "0x99aabbccddeeff"

        let http: CCIPResolver.HTTPClient = { request, _ in
            XCTAssertEqual(request.url.absoluteString, "https://gw.example/lookup")
            let body = try JSONSerialization.data(withJSONObject: ["data": gatewayHex])
            return .init(status: 200, body: body)
        }
        let ethCall: CCIPResolver.EthCallExecutor = { to, data in
            XCTAssertEqual(to.lowercased(), lookup.address.asString().lowercased())
            XCTAssertTrue(data.hasPrefix("0x11223344"))
            return finalHex
        }

        let result = try await CCIPResolver.resolve(
            revertData: revert, ethCall: ethCall, http: http, timeout: 1
        )
        XCTAssertEqual(result, finalHex)
    }

    func testResolveFallsThroughOn5xxThenSucceeds() async throws {
        let lookup = OffchainLookup(
            address: .zero,
            urls: ["https://first.example/x", "https://second.example/x"],
            callData: Data(), callbackFunction: Data(repeating: 0, count: 4), extraData: Data()
        )
        let revert = try encodedRevert(lookup: lookup)

        var seen: [String] = []
        let http: CCIPResolver.HTTPClient = { request, _ in
            seen.append(request.url.host ?? "")
            if seen.count == 1 {
                return .init(status: 503, body: Data())
            }
            let body = try JSONSerialization.data(withJSONObject: ["data": "0xbeef"])
            return .init(status: 200, body: body)
        }
        let ethCall: CCIPResolver.EthCallExecutor = { _, _ in "0xfeedface" }
        let result = try await CCIPResolver.resolve(
            revertData: revert, ethCall: ethCall, http: http, timeout: 1
        )
        XCTAssertEqual(result, "0xfeedface")
        XCTAssertEqual(seen, ["first.example", "second.example"])
    }

    func testResolveStopsOn4xx() async throws {
        let lookup = OffchainLookup(
            address: .zero,
            urls: ["https://first.example/x", "https://second.example/x"],
            callData: Data(), callbackFunction: Data(repeating: 0, count: 4), extraData: Data()
        )
        let revert = try encodedRevert(lookup: lookup)
        var seen: [String] = []
        let http: CCIPResolver.HTTPClient = { request, _ in
            seen.append(request.url.host ?? "")
            return .init(status: 403, body: Data())
        }
        let ethCall: CCIPResolver.EthCallExecutor = { _, _ in XCTFail("unreachable"); return "" }

        do {
            _ = try await CCIPResolver.resolve(
                revertData: revert, ethCall: ethCall, http: http, timeout: 1
            )
            XCTFail("expected throw")
        } catch CCIPResolver.CCIPError.clientError(let status) {
            XCTAssertEqual(status, 403)
        }
        XCTAssertEqual(seen, ["first.example"])  // stopped at first 4xx
    }

    func testResolveAllGatewaysFailed() async throws {
        let lookup = OffchainLookup(
            address: .zero, urls: ["https://first.example/x"],
            callData: Data(), callbackFunction: Data(repeating: 0, count: 4), extraData: Data()
        )
        let revert = try encodedRevert(lookup: lookup)
        let http: CCIPResolver.HTTPClient = { _, _ in
            throw URLError(.timedOut)
        }
        let ethCall: CCIPResolver.EthCallExecutor = { _, _ in XCTFail("unreachable"); return "" }

        do {
            _ = try await CCIPResolver.resolve(
                revertData: revert, ethCall: ethCall, http: http, timeout: 1
            )
            XCTFail("expected throw")
        } catch CCIPResolver.CCIPError.allGatewaysFailed {
            // ok
        }
    }

    /// The callback may itself revert with OffchainLookup — ethers.js behavior.
    /// We chain two levels and verify the second gateway is consulted.
    func testResolveFollowsCallbackRedirect() async throws {
        let inner = OffchainLookup(
            address: .zero, urls: ["https://level2.example/x"],
            callData: Data([0x02]), callbackFunction: Data([0xaa, 0xbb, 0xcc, 0xdd]), extraData: Data()
        )
        let innerRevert = try encodedRevert(lookup: inner)

        let outer = OffchainLookup(
            address: .zero, urls: ["https://level1.example/x"],
            callData: Data([0x01]), callbackFunction: Data(repeating: 0, count: 4), extraData: Data()
        )
        let outerRevert = try encodedRevert(lookup: outer)

        var calls = 0
        let http: CCIPResolver.HTTPClient = { _, _ in
            let body = try JSONSerialization.data(withJSONObject: ["data": "0x01"])
            return .init(status: 200, body: body)
        }
        let ethCall: CCIPResolver.EthCallExecutor = { _, _ in
            calls += 1
            if calls == 1 {
                throw RPCError.executionRevert(data: innerRevert.web3.hexString)
            }
            return "0xfinal"
        }
        let result = try await CCIPResolver.resolve(
            revertData: outerRevert, ethCall: ethCall, http: http, timeout: 1
        )
        XCTAssertEqual(result, "0xfinal")
        XCTAssertEqual(calls, 2)
    }

    func testResolveCapsAtMaxRedirects() async throws {
        // Each callback keeps reverting with the same OffchainLookup — a
        // hostile gateway scenario. Cap must prevent infinite recursion.
        let lookup = OffchainLookup(
            address: .zero, urls: ["https://gw.example/x"],
            callData: Data(), callbackFunction: Data(repeating: 0, count: 4), extraData: Data()
        )
        let revert = try encodedRevert(lookup: lookup)
        let http: CCIPResolver.HTTPClient = { _, _ in
            let body = try JSONSerialization.data(withJSONObject: ["data": "0x00"])
            return .init(status: 200, body: body)
        }
        let ethCall: CCIPResolver.EthCallExecutor = { _, _ in
            throw RPCError.executionRevert(data: revert.web3.hexString)
        }
        do {
            _ = try await CCIPResolver.resolve(
                revertData: revert, ethCall: ethCall, http: http, timeout: 1
            )
            XCTFail("expected throw")
        } catch CCIPResolver.CCIPError.tooManyRedirects {
            // ok
        }
    }

    /// A non-OffchainLookup revert inside the callback is terminal — it
    /// must propagate as RPCError.executionRevert so the leg classifies
    /// it normally (NO_RESOLVER, NO_CONTENTHASH, etc.).
    func testResolvePropagatesNonCCIPCallbackRevert() async throws {
        let lookup = OffchainLookup(
            address: .zero, urls: ["https://gw.example/x"],
            callData: Data(), callbackFunction: Data(repeating: 0, count: 4), extraData: Data()
        )
        let revert = try encodedRevert(lookup: lookup)
        let http: CCIPResolver.HTTPClient = { _, _ in
            let body = try JSONSerialization.data(withJSONObject: ["data": "0x00"])
            return .init(status: 200, body: body)
        }
        let ethCall: CCIPResolver.EthCallExecutor = { _, _ in
            throw RPCError.executionRevert(data: "0x77209fe8")  // NO_RESOLVER selector
        }
        do {
            _ = try await CCIPResolver.resolve(
                revertData: revert, ethCall: ethCall, http: http, timeout: 1
            )
            XCTFail("expected throw")
        } catch RPCError.executionRevert(let data) {
            XCTAssertEqual(data, "0x77209fe8")
        }
    }

    // MARK: Helpers

    private func encodedRevert(lookup: OffchainLookup) throws -> Data {
        let encoder = ABIFunctionEncoder(OffchainLookup.name)
        try lookup.encode(to: encoder)
        return try encoder.encoded()
    }
}
