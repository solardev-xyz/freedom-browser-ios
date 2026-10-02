import XCTest
@testable import Freedom

/// The external Swarm endpoint: what is accepted, and that every HTTP
/// user follows the one gateway value.
final class SwarmGatewayTests: XCTestCase {
    override func tearDown() { SwarmGateway.shared.setExternal(nil) }

    func testAcceptsHTTPSAnywhereAndCleartextOnlyLocally() {
        XCTAssertEqual(try SwarmGateway.parseExternal(" https://Bee.Example.com/ ").get().absoluteString, "https://bee.example.com")
        XCTAssertEqual(try SwarmGateway.parseExternal("http://192.168.1.20:1633").get().absoluteString, "http://192.168.1.20:1633")
        XCTAssertEqual(try SwarmGateway.parseExternal("http://bee.local:1633/api/").get().absoluteString, "http://bee.local:1633/api")
        XCTAssertEqual(SwarmGateway.parseExternal("http://bee.example.com"), .failure(.insecurePublicHost))
        XCTAssertEqual(SwarmGateway.parseExternal(""), .failure(.empty))
        for bad in ["bee.example.com", "ftp://x", "https://", "https://a.example?x=1", "https://u@a.example", "https://a.example#f"] {
            XCTAssertEqual(SwarmGateway.parseExternal(bad), .failure(.invalid), bad)
        }
    }

    func testLocalHostTable() {
        for local in ["localhost", "127.0.0.1", "10.0.0.5", "192.168.0.1", "172.16.4.4", "172.31.255.1", "169.254.1.1", "bee.local", "::1", "[fe80::1]", "fd00::1"] {
            XCTAssertTrue(SwarmGateway.isLocalHost(local), local)
        }
        for remote in ["bee.example.com", "8.8.8.8", "172.32.0.1", "192.169.0.1", "fdsomething.com", "2001:db8::1"] {
            XCTAssertFalse(SwarmGateway.isLocalHost(remote), remote)
        }
    }

    func testEveryHTTPUserFollowsTheGateway() throws {
        let hex = String(repeating: "ab", count: 32)
        XCTAssertEqual(BeeAPIClient.baseURL.absoluteString, "http://127.0.0.1:1633")
        XCTAssertEqual(SwarmSubscriptionSocket.wsBase.absoluteString, "ws://127.0.0.1:1633")
        XCTAssertEqual(BzzSchemeHandler.localHTTPURL(for: URL(string: "bzz://\(hex)/a/b")!)?.absoluteString, "http://127.0.0.1:1633/bzz/\(hex)/a/b")

        SwarmGateway.shared.setExternal(try SwarmGateway.parseExternal("https://bee.example.com/api").get())
        XCTAssertEqual(BeeAPIClient.baseURL.absoluteString, "https://bee.example.com/api")
        XCTAssertEqual(SwarmSubscriptionSocket.wsBase.absoluteString, "wss://bee.example.com/api")
        XCTAssertEqual(BzzSchemeHandler.localHTTPURL(for: URL(string: "bzz://\(hex)/a/b?x=1")!)?.absoluteString, "https://bee.example.com/api/bzz/\(hex)/a/b?x=1")
        XCTAssertEqual(BzzSchemeHandler.localHTTPURL(for: URL(string: "bzz://x.eth/bytes/\(hex)")!)?.absoluteString, "https://bee.example.com/api/bytes/\(hex)")
        XCTAssertEqual(SwarmGateway.shared.url(path: "/stamps", query: "a=1")?.absoluteString, "https://bee.example.com/api/stamps?a=1")
        XCTAssertTrue(SwarmGateway.shared.isExternal)
    }
}
