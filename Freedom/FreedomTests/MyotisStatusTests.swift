import XCTest
import MyotisKit
@testable import Freedom

/// Pure decode + readiness gating for the Myotis wrapper — the decision
/// tables that decide when the resolver attempts the P2P tier. No live
/// engine involved.
final class MyotisStatusTests: XCTestCase {
    // MARK: - MyotisChainStatus.decode / ready

    private func status(
        beacon: String = "SYNCED",
        snapPeers: Int = 1,
        running: Bool = true,
        paused: Bool = false
    ) -> String {
        """
        {"beaconState":"\(beacon)","peerCount":3,"snapPeers":\(snapPeers),
         "executionBlockNumber":25760849,"finalizedBlockNumber":25760800,
         "running":\(running),"paused":\(paused)}
        """
    }

    func testSyncedWithSnapPeerIsReady() {
        let decoded = MyotisChainStatus.decode(status())
        XCTAssertTrue(decoded.ready)
        XCTAssertEqual(decoded.executionBlockNumber, 25_760_849)
        XCTAssertEqual(decoded.peerCount, 3)
    }

    func testSyncedWithoutSnapPeerIsNotReady() {
        // The Phase 0 spike's warm-up window: beacon SYNCED but every
        // read fails "no snap peer available". The gate must hold the
        // tier back here.
        XCTAssertFalse(MyotisChainStatus.decode(status(snapPeers: 0)).ready)
    }

    func testSyncingIsNotReady() {
        XCTAssertFalse(MyotisChainStatus.decode(status(beacon: "SYNCING")).ready)
    }

    func testPausedIsNotReady() {
        XCTAssertFalse(MyotisChainStatus.decode(status(paused: true)).ready)
    }

    func testNotRunningIsNotReady() {
        XCTAssertFalse(MyotisChainStatus.decode(status(running: false)).ready)
    }

    func testUnknownHandleEmptyObjectIsNotReady() {
        // The engine returns "{}" for an unknown handle.
        XCTAssertFalse(MyotisChainStatus.decode("{}").ready)
    }

    func testGarbageDecodesToNotReady() {
        XCTAssertFalse(MyotisChainStatus.decode("not json").ready)
    }

    // MARK: - MyotisCallOutcome.decode

    func testOkOutcome() {
        XCTAssertEqual(
            MyotisCallOutcome.decode(#"{"status":"ok","resultHex":"0xdeadbeef"}"#),
            .ok(resultHex: "0xdeadbeef")
        )
    }

    func testRevertOutcome() {
        XCTAssertEqual(
            MyotisCallOutcome.decode(#"{"status":"revert","dataHex":"0x08c379a0"}"#),
            .revert(dataHex: "0x08c379a0")
        )
    }

    func testUnavailableOutcome() {
        XCTAssertEqual(
            MyotisCallOutcome.decode(#"{"status":"unavailable","reason":"no snap peer available"}"#),
            .unavailable(reason: "no snap peer available")
        )
    }

    func testErrorOutcome() {
        XCTAssertEqual(
            MyotisCallOutcome.decode(#"{"error":"state unavailable for 0xabc"}"#),
            .error("state unavailable for 0xabc")
        )
    }

    func testUndecodableIsError() {
        guard case .error = MyotisCallOutcome.decode("garbage") else {
            return XCTFail("expected .error for undecodable input")
        }
    }

    func testUnknownStatusIsError() {
        guard case .error = MyotisCallOutcome.decode(#"{"status":"partial"}"#) else {
            return XCTFail("expected .error for unknown status")
        }
    }
}
