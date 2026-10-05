import SwarmKit
import XCTest
@testable import Freedom

/// The node sheet tells "not loaded yet" from "loaded, nothing there":
/// stamps and balances are loading until the node's first answer.
@MainActor
final class SwarmLoadingStateTests: XCTestCase {
    /// Serves canned bodies by path; anything else fails like a node
    /// that isn't up yet.
    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var bodies: [String: String] = [:]

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let path = request.url?.path ?? ""
            guard let body = Self.bodies[path] else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    /// Main-actor fixtures outlive the test body (see SitePermissionStoreTests).
    private var keep: [AnyObject] = []

    private func bee() -> BeeAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return BeeAPIClient(session: URLSession(configuration: config))
    }

    override func tearDown() {
        StubProtocol.bodies = [:]
        super.tearDown()
    }

    func testStampsAreLoadingUntilTheNodeAnswers() async {
        let swarm = SwarmNode()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "SwarmLoading-\(UUID().uuidString)")!)
        let service = StampService(swarm: swarm, settings: settings, bee: bee())
        keep += [swarm, settings, service]

        await service.refreshStamps()
        XCTAssertFalse(service.hasLoaded, "no answer yet: loading, not empty")

        StubProtocol.bodies["/stamps"] = #"{"stamps":[]}"#
        await service.refreshStamps()
        XCTAssertTrue(service.hasLoaded)
        XCTAssertTrue(service.stamps.isEmpty, "loaded, and really empty")
    }

    func testBalancesAreLoadingUntilTheWalletAnswers() async {
        let swarm = SwarmNode()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "SwarmLoading-\(UUID().uuidString)")!)
        let wallet = BeeWalletInfo(swarm: swarm, settings: settings, bee: bee())
        keep += [swarm, settings, wallet]

        await wallet.refresh()
        XCTAssertFalse(wallet.hasLoaded)

        StubProtocol.bodies["/wallet"] = #"{"nativeTokenBalance":"495500000000000000","bzzBalance":"870283000000000000"}"#
        StubProtocol.bodies["/chequebook/balance"] = #"{"availableBalance":"1013000000000000"}"#
        await wallet.refresh()
        XCTAssertTrue(wallet.hasLoaded)
        XCTAssertEqual(wallet.nodeXdai?.description, "495500000000000000")
        XCTAssertEqual(wallet.chequebookXbzz?.description, "1013000000000000")
    }
}
