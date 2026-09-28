import XCTest
@testable import Freedom

/// Manifest validation + fingerprinting — desktop's `validateManifest`
/// / `fingerprint` contract, byte for byte where it matters.
final class SwarmManifestTests: XCTestCase {
    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func manifest(
        schema: String = "freedom-manifest/1",
        name: String = "Notes",
        description: String? = "A tiny notes app",
        swarm: [String: Any] = ["publish": ["why": "Save your notes to Swarm"]]
    ) -> [String: Any] {
        var root: [String: Any] = ["schema": schema, "name": name, "capabilities": ["swarm": swarm]]
        if let description { root["description"] = description }
        return root
    }

    func testAcceptsAWellFormedManifest() throws {
        let parsed = try SwarmManifest.validate(json(manifest(swarm: [
            "publish": ["why": "Save notes"],
            "feeds": ["why": "Keep a list of notes"],
        ])))
        XCTAssertEqual(parsed.name, "Notes")
        XCTAssertEqual(parsed.description, "A tiny notes app")
        XCTAssertEqual(parsed.declared, [.publish, .feeds])
        XCTAssertEqual(parsed.capabilities[.feeds], "Keep a list of notes")
    }

    func testDescriptionIsOptional() throws {
        let parsed = try SwarmManifest.validate(json(manifest(description: nil)))
        XCTAssertEqual(parsed.description, "")
    }

    func testRejectsUnknownSchemaFieldsAndCapabilities() {
        XCTAssertThrowsError(try SwarmManifest.validate(json(manifest(schema: "freedom-manifest/2"))))
        var extra = manifest()
        extra["homepage"] = "https://example.com"
        XCTAssertThrowsError(try SwarmManifest.validate(json(extra)))
        XCTAssertThrowsError(try SwarmManifest.validate(json(manifest(swarm: ["wallet": ["why": "x"]]))))
        XCTAssertThrowsError(try SwarmManifest.validate(json(manifest(swarm: [:]))))
        XCTAssertThrowsError(try SwarmManifest.validate(json(manifest(swarm: ["publish": ["why": "x", "scope": "all"]]))))
        XCTAssertThrowsError(try SwarmManifest.validate(Data("not json".utf8)))
        XCTAssertThrowsError(try SwarmManifest.validate(json(["a", "b"])))
    }

    func testRejectsUnsafeOrOversizedDisplayText() {
        XCTAssertThrowsError(try SwarmManifest.validate(json(manifest(name: String(repeating: "n", count: 33)))))
        XCTAssertThrowsError(try SwarmManifest.validate(json(manifest(name: "   "))))
        XCTAssertThrowsError(try SwarmManifest.validate(json(manifest(name: "Notes\u{202e}"))))
        XCTAssertThrowsError(try SwarmManifest.validate(json(manifest(description: String(repeating: "d", count: 161)))))
        XCTAssertThrowsError(try SwarmManifest.validate(json(manifest(swarm: ["publish": ["why": String(repeating: "w", count: 141)]]))))
        XCTAssertThrowsError(try SwarmManifest.validate(json(manifest(swarm: ["publish": ["why": "line\nbreak"]]))))
        XCTAssertThrowsError(try SwarmManifest.validate(json(manifest(swarm: ["publish": ["why": ""]]))))
        // Length is counted in code points, like desktop's `Array.from`.
        XCTAssertNoThrow(try SwarmManifest.validate(json(manifest(name: String(repeating: "é", count: 32)))))
    }

    func testFingerprintIgnoresWordingButNotCapabilitySet() throws {
        let a = try SwarmManifest.validate(json(manifest(swarm: ["publish": ["why": "one"], "feeds": ["why": "two"]])))
        let b = try SwarmManifest.validate(json(manifest(name: "Other", swarm: ["feeds": ["why": "x"], "publish": ["why": "y"]])))
        let c = try SwarmManifest.validate(json(manifest(swarm: ["publish": ["why": "one"]])))
        XCTAssertEqual(a.fingerprint, b.fingerprint)
        XCTAssertNotEqual(a.fingerprint, c.fingerprint)
        // Desktop: sha256(JSON.stringify({schema, capabilities: sortedKeys})).
        let expected = SwarmManifest.sha256Hex(Data("{\"schema\":\"freedom-manifest/1\",\"capabilities\":[\"feeds\",\"publish\"]}".utf8))
        XCTAssertEqual(a.fingerprint, expected)
    }

    func testStatusClassification() {
        XCTAssertNil(SwarmManifestFetcher.classify(status: 200))
        XCTAssertEqual(SwarmManifestFetcher.classify(status: 404), .absent)
        XCTAssertEqual(SwarmManifestFetcher.classify(status: 403), .invalid)
        XCTAssertEqual(SwarmManifestFetcher.classify(status: 502), .unresolved)
    }

    func testOversizedOrMalformedBodiesAreInvalid() {
        let big = Data(repeating: 0x20, count: SwarmManifest.maxBytes + 1)
        XCTAssertEqual(SwarmManifestFetcher.accept(body: big, host: "x"), .invalid)
        XCTAssertEqual(SwarmManifestFetcher.accept(body: Data("{".utf8), host: "x"), .invalid)
        guard case .found(let parsed, let rawHash) = SwarmManifestFetcher.accept(body: json(manifest()), host: "x") else {
            return XCTFail("expected found")
        }
        XCTAssertEqual(parsed.name, "Notes")
        XCTAssertEqual(rawHash.count, 64)
    }
}
