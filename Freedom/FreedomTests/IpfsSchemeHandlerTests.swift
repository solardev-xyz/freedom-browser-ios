import XCTest
@testable import Freedom

final class IpfsSchemeHandlerTests: XCTestCase {
    private let exampleCID = "bafybeiaql2jo3fu5b7c4lmpoi5drh5sam7yt652shwdgwbky4o7uw33u2u"

    // MARK: - CID/IPNS-key host path (unchanged from pre-#1)

    func testIpfsCIDHostMapsToGatewayPath() {
        let url = URL(string: "ipfs://\(exampleCID)/index.html")!
        XCTAssertEqual(IpfsSchemeHandler.gatewayStylePath(for: url), "/ipfs/\(exampleCID)/index.html")
    }

    func testIpnsKeyHostMapsToGatewayPath() {
        let key = "k51qzi5uqu5dgr6hxlnvbmhrqnpx4xpzr1mfg9o3pqzr6q3rvkqyhvsd9hjwa6"
        let url = URL(string: "ipns://\(key)/foo")!
        XCTAssertEqual(IpfsSchemeHandler.gatewayStylePath(for: url), "/ipns/\(key)/foo")
    }

    func testNestedIpfsPathPassesThrough() {
        // Relative `/ipfs/<other-cid>/...` fetch arriving as
        // ipfs://<page-cid>/ipfs/<other-cid>/...
        let other = "bafkreih2222222222222222222222222222222222222222222222222"
        let url = URL(string: "ipfs://\(exampleCID)/ipfs/\(other)/x.css")!
        XCTAssertEqual(IpfsSchemeHandler.gatewayStylePath(for: url), "/ipfs/\(other)/x.css")
    }

    // MARK: - ENS-resolved path

    func testENSResolvedIpfsUsesResolvedCIDInPath() {
        let url = URL(string: "ipfs://vitalik.eth/sub/page.html")!
        let path = IpfsSchemeHandler.gatewayStylePath(for: url, resolvedTo: exampleCID)
        XCTAssertEqual(path, "/ipfs/\(exampleCID)/sub/page.html")
    }

    func testENSResolvedIpnsUsesResolvedKeyInPath() {
        let resolvedKey = "k51qzi5uqu5dgr6hxlnvbmhrqnpx4xpzr1mfg9o3pqzr6q3rvkqyhvsd9hjwa6"
        let url = URL(string: "ipns://docs.example.eth/")!
        let path = IpfsSchemeHandler.gatewayStylePath(for: url, resolvedTo: resolvedKey)
        XCTAssertEqual(path, "/ipns/\(resolvedKey)/")
    }

    func testENSResolvedDoesNotOverrideNestedIpfsPath() {
        // Nested-fetch passthrough holds even on an ENS-resolved
        // navigation — the explicit inner CID wins.
        let other = "bafybeih7777777777777777777777777777777777777777777777777"
        let url = URL(string: "ipfs://vitalik.eth/ipfs/\(other)/asset.png")!
        let path = IpfsSchemeHandler.gatewayStylePath(for: url, resolvedTo: exampleCID)
        XCTAssertEqual(path, "/ipfs/\(other)/asset.png")
    }

    // MARK: - Guards

    func testNonIpfsSchemeReturnsNil() {
        let url = URL(string: "bzz://something/")!
        XCTAssertNil(IpfsSchemeHandler.gatewayStylePath(for: url))
    }

    // MARK: - Native FFI request JSON builder

    func testNativeRequestJSONIncludesMethodPathAndIDs() throws {
        let json = try IpfsSchemeHandler.buildNativeRequestJSON(
            method: "get",
            gatewayPath: "/ipfs/\(exampleCID)/index.html",
            headers: ["Accept": "*/*"],
            requestID: 42,
            parentRequestID: 7,
            topLevelPath: "/ipfs/\(exampleCID)/"
        )
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertEqual(decoded["method"] as? String, "GET")
        XCTAssertEqual(decoded["path"] as? String, "/ipfs/\(exampleCID)/index.html")
        XCTAssertEqual(decoded["request_id"] as? UInt64, 42)
        XCTAssertEqual(decoded["parent_request_id"] as? UInt64, 7)
        XCTAssertEqual(decoded["top_level_path"] as? String, "/ipfs/\(exampleCID)/")
        let headers = decoded["headers"] as! [[String: String]]
        XCTAssertEqual(headers, [["name": "Accept", "value": "*/*"]])
    }

    func testNativeRequestJSONForwardsRangeAndConditionalHeaders() throws {
        let headers: [String: String] = [
            "Range": "bytes=0-1023",
            "If-None-Match": "\"abc\"",
            "Accept-Encoding": "gzip",
        ]
        let json = try IpfsSchemeHandler.buildNativeRequestJSON(
            method: "GET",
            gatewayPath: "/ipfs/\(exampleCID)/big.bin",
            headers: headers,
            requestID: 1,
            parentRequestID: nil,
            topLevelPath: nil
        )
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let actual = decoded["headers"] as! [[String: String]]
        let names = Set(actual.map { $0["name"]! })
        XCTAssertEqual(names, ["Range", "If-None-Match", "Accept-Encoding"])
    }

    func testNativeRequestJSONStripsHostAndCorrelationHeaders() throws {
        // Host is dropped because the native FFI path has no socket
        // peer; X-Freedom-* are stamped by Rust from the JSON
        // top-level fields, so passing them in `headers` would
        // double-stamp.
        let headers: [String: String] = [
            "Accept": "text/html",
            "Host": "ignored.example",
            "X-Freedom-Request-ID": "999",
            "X-Freedom-Parent-Request-ID": "888",
            "X-Freedom-Top-Level-Path": "/ipfs/other",
        ]
        let json = try IpfsSchemeHandler.buildNativeRequestJSON(
            method: "GET",
            gatewayPath: "/ipfs/\(exampleCID)/",
            headers: headers,
            requestID: 1,
            parentRequestID: nil,
            topLevelPath: nil
        )
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let actual = decoded["headers"] as! [[String: String]]
        XCTAssertEqual(actual.count, 1)
        XCTAssertEqual(actual.first?["name"], "Accept")
    }

    func testNativeRequestJSONOmitsParentAndTopLevelWhenNil() throws {
        let json = try IpfsSchemeHandler.buildNativeRequestJSON(
            method: "GET",
            gatewayPath: "/ipfs/\(exampleCID)/",
            headers: [:],
            requestID: 1,
            parentRequestID: nil,
            topLevelPath: nil
        )
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertNil(decoded["parent_request_id"])
        XCTAssertNil(decoded["top_level_path"])
        XCTAssertEqual(decoded["request_id"] as? UInt64, 1)
    }

    func testNativeRequestJSONHeadersAreDeterministicallyOrdered() throws {
        let headers: [String: String] = [
            "Z-Last": "z",
            "A-First": "a",
            "M-Middle": "m",
        ]
        let json = try IpfsSchemeHandler.buildNativeRequestJSON(
            method: "GET",
            gatewayPath: "/ipfs/\(exampleCID)/",
            headers: headers,
            requestID: nil,
            parentRequestID: nil,
            topLevelPath: nil
        )
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let actual = (decoded["headers"] as! [[String: String]]).map { $0["name"]! }
        XCTAssertEqual(actual, ["A-First", "M-Middle", "Z-Last"])
    }

    // MARK: - Native FFI response metadata decoder

    func testNativeResponseMetadataDecodesStreamingState() throws {
        let json = """
        {
          "handle": 1,
          "state": "streaming",
          "method": "GET",
          "path": "/ipfs/bafy/index.html",
          "namespace": "ipfs",
          "request_id": 42,
          "status": 200,
          "headers": [
            {"name": "content-type", "value": "text/html; charset=utf-8"},
            {"name": "content-length", "value": "1234"}
          ],
          "completed": false,
          "cancelled": false,
          "error": null
        }
        """
        let meta = try IpfsSchemeHandler.decodeNativeResponseMetadata(json)
        XCTAssertEqual(meta.state, .streaming)
        XCTAssertEqual(meta.status, 200)
        XCTAssertEqual(meta.headers?.count, 2)
        XCTAssertEqual(meta.headers?.first?.name, "content-type")
        XCTAssertEqual(meta.cancelled, false)
        XCTAssertNil(meta.error)
    }

    func testNativeResponseMetadataDecodesFailedStateWithError() throws {
        let json = """
        {
          "state": "failed",
          "status": null,
          "headers": null,
          "completed": false,
          "cancelled": false,
          "error": { "code": "not_found", "message": "block not retrieved" }
        }
        """
        let meta = try IpfsSchemeHandler.decodeNativeResponseMetadata(json)
        XCTAssertEqual(meta.state, .failed)
        XCTAssertNil(meta.status)
        XCTAssertEqual(meta.error?.code, "not_found")
        XCTAssertEqual(meta.error?.message, "block not retrieved")
    }

    func testNativeResponseMetadataDecodesPendingState() throws {
        let json = """
        {
          "state": "pending",
          "status": null,
          "headers": null,
          "completed": false,
          "cancelled": false,
          "error": null
        }
        """
        let meta = try IpfsSchemeHandler.decodeNativeResponseMetadata(json)
        XCTAssertEqual(meta.state, .pending)
        XCTAssertNil(meta.status)
        XCTAssertNil(meta.headers)
    }
}
