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

    // MARK: Gateway URL safety (audit fix P2c)

    /// Each CCIP leg fires the gateway request from a single untrusted
    /// RPC leg before any quorum agreement on the revert data. A malicious
    /// provider could otherwise steer the client at loopback, private, or
    /// link-local targets. isSafeGatewayURL is the defense-in-depth gate.

    func testGatewayURLAcceptsHTTPSPublic() {
        XCTAssertTrue(CCIPResolver.isSafeGatewayURL(URL(string: "https://gw.example.com/x")!))
        XCTAssertTrue(CCIPResolver.isSafeGatewayURL(URL(string: "https://8.8.8.8/x")!))
    }

    func testGatewayURLRejectsHTTP() {
        XCTAssertFalse(CCIPResolver.isSafeGatewayURL(URL(string: "http://gw.example.com/x")!))
    }

    func testGatewayURLRejectsLocalhost() {
        XCTAssertFalse(CCIPResolver.isSafeGatewayURL(URL(string: "https://localhost/x")!))
        XCTAssertFalse(CCIPResolver.isSafeGatewayURL(URL(string: "https://LOCALHOST/x")!))
    }

    func testGatewayURLRejectsMDNS() {
        XCTAssertFalse(CCIPResolver.isSafeGatewayURL(URL(string: "https://mybox.local/x")!))
    }

    func testGatewayURLRejectsIPv4LoopbackAndPrivate() {
        let blocked = [
            "https://127.0.0.1/x",
            "https://127.5.5.5/x",
            "https://10.0.0.1/x",
            "https://172.16.0.1/x",
            "https://172.31.255.255/x",
            "https://192.168.1.1/x",
            "https://169.254.169.254/x",   // AWS metadata-style
            "https://0.0.0.0/x",
            "https://224.0.0.1/x",
        ]
        for s in blocked {
            XCTAssertFalse(
                CCIPResolver.isSafeGatewayURL(URL(string: s)!),
                "expected \(s) to be rejected"
            )
        }
    }

    func testGatewayURLAcceptsIPv4AtBoundary() {
        // Just outside the private ranges — should still be allowed.
        XCTAssertTrue(CCIPResolver.isSafeGatewayURL(URL(string: "https://172.15.255.255/x")!))
        XCTAssertTrue(CCIPResolver.isSafeGatewayURL(URL(string: "https://172.32.0.0/x")!))
        XCTAssertTrue(CCIPResolver.isSafeGatewayURL(URL(string: "https://11.0.0.1/x")!))
    }

    func testGatewayURLRejectsIPv4MappedIPv6Private() {
        // ::ffff:a.b.c.d must route through the IPv4 classifier —
        // two samples exercise the dispatch (loopback + RFC1918);
        // exhaustive v4 coverage lives in testGatewayURLRejectsIPv4LoopbackAndPrivate.
        XCTAssertFalse(CCIPResolver.isSafeGatewayURL(URL(string: "https://[::ffff:127.0.0.1]/x")!))
        XCTAssertFalse(CCIPResolver.isSafeGatewayURL(URL(string: "https://[::ffff:10.0.0.1]/x")!))
    }

    func testGatewayURLAcceptsIPv4MappedPublic() {
        // ::ffff:8.8.8.8 is a public v4 target smuggled as v6 — still
        // legitimate; accept to match the real-v4 policy.
        XCTAssertTrue(
            CCIPResolver.isSafeGatewayURL(URL(string: "https://[::ffff:8.8.8.8]/x")!)
        )
    }

    func testGatewayURLRejectsIPv6LoopbackAndPrivate() {
        let blocked = [
            "https://[::1]/x",           // loopback
            "https://[::]/x",            // unspecified
            "https://[fe80::1]/x",       // link-local
            "https://[fc00::1]/x",       // unique-local
            "https://[fd12:3456::1]/x",  // unique-local
            "https://[ff02::1]/x",       // multicast
        ]
        for s in blocked {
            XCTAssertFalse(
                CCIPResolver.isSafeGatewayURL(URL(string: s)!),
                "expected \(s) to be rejected"
            )
        }
    }

    /// A gateway that 302s (which URLSession would normally auto-follow,
    /// bypassing isSafeGatewayURL on the redirect target) is treated as
    /// a refused redirect: the 3xx response body is unparseable and we
    /// fall through to the next gateway. Exercises the policy in
    /// fetchFromGateways; the actual redirect-refusal is enforced at the
    /// URLSession delegate level (integration-tested out of band).
    func testResolveFallsThroughOnRedirectStatus() async throws {
        let lookup = OffchainLookup(
            address: .zero,
            urls: ["https://first.example.com/x", "https://second.example.com/x"],
            callData: Data(), callbackFunction: Data(repeating: 0, count: 4), extraData: Data()
        )
        let revert = try encodedRevert(lookup: lookup)
        var seen: [String] = []
        let http: CCIPResolver.HTTPClient = { request, _ in
            seen.append(request.url.host ?? "")
            if seen.count == 1 {
                // Simulate refused-redirect response: 302 with empty body.
                return .init(status: 302, body: Data())
            }
            let body = try JSONSerialization.data(withJSONObject: ["data": "0xbeef"])
            return .init(status: 200, body: body)
        }
        let ethCall: CCIPResolver.EthCallExecutor = { _, _ in "0xok" }
        let result = try await CCIPResolver.resolve(
            revertData: revert, ethCall: ethCall, http: http, timeout: 1
        )
        XCTAssertEqual(result, "0xok")
        XCTAssertEqual(seen, ["first.example.com", "second.example.com"])
    }

    func testBuildRequestRejectsUnsafeURL() {
        // End-to-end: attacker-supplied localhost URL → buildRequest nils out.
        XCTAssertNil(CCIPResolver.buildRequest(
            template: "https://127.0.0.1:8080/admin",
            sender: "0xabc", callData: "0x01"
        ))
        XCTAssertNil(CCIPResolver.buildRequest(
            template: "http://gw.example.com/x",
            sender: "0xabc", callData: "0x01"
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
