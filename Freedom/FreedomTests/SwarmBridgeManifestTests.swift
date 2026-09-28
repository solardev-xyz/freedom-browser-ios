import XCTest
@testable import Freedom

/// The bridge's manifest gate: a `bzz://` app's manifest is discovered
/// on `swarm_requestAccess`, consented to once per page load, and its
/// batch decision replaces the ordinary connect sheet.
@MainActor
final class SwarmBridgeManifestTests: XCTestCase {
    private var fixture: SwarmBridgeTestFixture!

    private let ref = String(repeating: "cd", count: 32)
    private var origin: OriginIdentity { OriginIdentity.from(string: "bzz://\(ref)")! }

    override func setUp() async throws {
        fixture = try await SwarmBridgeTestFixture()
        fixture.host.displayURL = URL(string: "bzz://\(ref)/")
    }

    override func tearDown() async throws {
        try await fixture.tearDownAsync()
        fixture = nil
    }

    private func serveManifest(_ capabilities: [SwarmManifestCapability: String]) {
        let manifest = SwarmManifest(schema: SwarmManifest.schema, name: "Notes", description: "", capabilities: capabilities)
        fixture.stubs.discoverManifest = { _ in .found(manifest: manifest, rawHash: "00") }
    }

    private var lastErrorCode: Int? { fixture.recorder.errors.last?.dict["code"] as? Int }

    func testRequestAccessConsentsViaTheManifestSheetOnly() async throws {
        serveManifest([.publish: "Save notes"])
        var parked: ApprovalRequest.Kind?
        fixture.setNextDecision(.approved, sideEffect: { [fixture] request in
            parked = request.kind
            guard case .swarmManifest(let details) = request.kind else { return }
            XCTAssertEqual(details.model.changed.map(\.capability), [.publish])
            _ = try? fixture!.manifestStore.decide(token: details.token, outcome: .allow)
        })
        await fixture.dispatch(method: "swarm_requestAccess", origin: origin)

        guard case .swarmManifest = parked else { return XCTFail("expected the manifest sheet, got \(String(describing: parked))") }
        XCTAssertTrue(fixture.stubs.pendingDecisions.isEmpty, "no second (connect) sheet")
        let result = try XCTUnwrap(fixture.recorder.results.last?.value as? [String: Any])
        XCTAssertEqual(result["connected"] as? Bool, true)
        XCTAssertTrue(fixture.permissionStore.isConnected(origin.key))
        XCTAssertTrue(fixture.permissionStore.isAutoApprovePublish(origin: origin.key))
    }

    func testDenialIsUserRejectedAndStaysCachedForThePage() async throws {
        serveManifest([.publish: "Save notes"])
        var discoveries = 0
        let served = fixture.stubs.discoverManifest!
        fixture.stubs.discoverManifest = { url in discoveries += 1; return await served(url) }
        fixture.setNextDecision(.denied)
        await fixture.dispatch(method: "swarm_requestAccess", origin: origin)
        XCTAssertEqual(lastErrorCode, 4001)
        XCTAssertNil(fixture.manifestStore.record(for: origin.key))

        // Same page load: no new discovery, no new sheet, same answer.
        await fixture.dispatch(method: "swarm_requestAccess", origin: origin, id: 2)
        XCTAssertEqual(fixture.recorder.errors.count, 2)
        XCTAssertEqual(lastErrorCode, 4001)
        XCTAssertEqual(discoveries, 1)

        // A navigation lifts it.
        fixture.host.displayURL = URL(string: "bzz://\(ref)/other")
        fixture.setNextDecision(.denied)
        await fixture.dispatch(method: "swarm_requestAccess", origin: origin, id: 3)
        XCTAssertEqual(discoveries, 2)
    }

    func testNonEagerMethodsNeverDiscover() async {
        var discoveries = 0
        fixture.stubs.discoverManifest = { _ in discoveries += 1; return .absent }
        await fixture.dispatch(method: "swarm_publishData", params: ["data": "x", "contentType": "text/plain"], origin: origin)
        XCTAssertEqual(discoveries, 0)
        XCTAssertEqual(lastErrorCode, 4100, "not connected — the ordinary path")
        await fixture.dispatch(method: "swarm_getCapabilities", origin: origin, id: 2)
        XCTAssertEqual(discoveries, 0)
    }

    func testUnresolvedRefreshOfAKnownAppFailsClosed() async throws {
        serveManifest([.publish: "Save notes"])
        fixture.setNextDecision(.approved, sideEffect: { [fixture] request in
            guard case .swarmManifest(let details) = request.kind else { return }
            _ = try? fixture!.manifestStore.decide(token: details.token, outcome: .allow)
        })
        await fixture.dispatch(method: "swarm_requestAccess", origin: origin)
        XCTAssertTrue(fixture.permissionStore.isConnected(origin.key))

        fixture.host.displayURL = URL(string: "bzz://\(ref)/next")
        fixture.stubs.discoverManifest = { _ in .unresolved }
        await fixture.dispatch(method: "swarm_publishData", params: ["data": "x", "contentType": "text/plain"], origin: origin, id: 2)
        XCTAssertEqual(lastErrorCode, 4900)
        XCTAssertTrue(fixture.permissionStore.isAutoApprovePublish(origin: origin.key), "grants survive a transient failure")
    }

    func testLegacyAppsStillGetTheConnectSheet() async {
        fixture.stubs.discoverManifest = { _ in .absent }
        var parked: ApprovalRequest.Kind?
        fixture.setNextDecision(.approved, sideEffect: { parked = $0.kind })
        await fixture.dispatch(method: "swarm_requestAccess", origin: origin)
        guard case .swarmConnect = parked else { return XCTFail("expected the connect sheet") }
        XCTAssertTrue(fixture.permissionStore.isConnected(origin.key))
    }
}
