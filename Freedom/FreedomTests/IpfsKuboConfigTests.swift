import XCTest
@testable import Freedom

final class IpfsKuboConfigTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kubocfg-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeConfig(_ json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try data.write(to: IpfsKuboConfig.configPath(for: tmpDir))
    }

    private func readConfig() throws -> [String: Any] {
        let data = try Data(contentsOf: IpfsKuboConfig.configPath(for: tmpDir))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    // MARK: - currentPeerID

    func testCurrentPeerIDReturnsNilWhenConfigMissing() throws {
        XCTAssertNil(try IpfsKuboConfig.currentPeerID(at: tmpDir))
    }

    func testCurrentPeerIDReturnsNilWhenIdentitySectionMissing() throws {
        try writeConfig(["Datastore": ["Path": "/foo"]])
        XCTAssertNil(try IpfsKuboConfig.currentPeerID(at: tmpDir))
    }

    func testCurrentPeerIDReturnsValueWhenPresent() throws {
        try writeConfig([
            "Identity": ["PeerID": "12D3KooWFoo", "PrivKey": "fake"],
            "Datastore": ["Path": "/foo"],
        ])
        XCTAssertEqual(try IpfsKuboConfig.currentPeerID(at: tmpDir), "12D3KooWFoo")
    }

    func testCurrentPeerIDThrowsOnMalformedJSON() throws {
        try Data("not json".utf8).write(to: IpfsKuboConfig.configPath(for: tmpDir))
        XCTAssertThrowsError(try IpfsKuboConfig.currentPeerID(at: tmpDir))
    }

    // MARK: - injectIdentity

    func testInjectIdentityRoundTrips() throws {
        try writeConfig([
            "Identity": ["PeerID": "12D3KooWOld", "PrivKey": "old-priv"],
        ])
        try IpfsKuboConfig.injectIdentity(
            at: tmpDir,
            peerID: "12D3KooWNew",
            privKeyBase64: "new-priv"
        )
        XCTAssertEqual(try IpfsKuboConfig.currentPeerID(at: tmpDir), "12D3KooWNew")
        let identity = try readConfig()["Identity"] as! [String: Any]
        XCTAssertEqual(identity["PrivKey"] as? String, "new-priv")
    }

    func testInjectIdentityPreservesOtherFields() throws {
        try writeConfig([
            "Identity": ["PeerID": "12D3KooWOld", "PrivKey": "old-priv"],
            "Datastore": ["Path": "/some/path"],
            "Bootstrap": ["nodeA", "nodeB"],
            "Routing": ["Type": "autoclient"],
            "Addresses": ["Gateway": "/ip4/127.0.0.1/tcp/5050"],
        ])
        try IpfsKuboConfig.injectIdentity(
            at: tmpDir,
            peerID: "12D3KooWNew",
            privKeyBase64: "new-priv"
        )
        let config = try readConfig()
        XCTAssertEqual((config["Datastore"] as? [String: Any])?["Path"] as? String, "/some/path")
        XCTAssertEqual(config["Bootstrap"] as? [String], ["nodeA", "nodeB"])
        XCTAssertEqual((config["Routing"] as? [String: Any])?["Type"] as? String, "autoclient")
        XCTAssertEqual((config["Addresses"] as? [String: Any])?["Gateway"] as? String, "/ip4/127.0.0.1/tcp/5050")
    }

    func testInjectIdentityCreatesIdentityWhenMissing() throws {
        try writeConfig(["Datastore": ["Path": "/foo"]])
        try IpfsKuboConfig.injectIdentity(
            at: tmpDir,
            peerID: "12D3KooWNew",
            privKeyBase64: "new-priv"
        )
        XCTAssertEqual(try IpfsKuboConfig.currentPeerID(at: tmpDir), "12D3KooWNew")
    }

    func testInjectIdentityThrowsWhenConfigMissing() {
        XCTAssertThrowsError(
            try IpfsKuboConfig.injectIdentity(at: tmpDir, peerID: "x", privKeyBase64: "y")
        ) { error in
            guard case IpfsKuboConfig.Error.configNotFound = error else {
                return XCTFail("expected .configNotFound, got \(error)")
            }
        }
    }
}
