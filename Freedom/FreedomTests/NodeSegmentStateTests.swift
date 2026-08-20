import XCTest
import SwarmKit
import IPFSKit
import MyotisKit
import RadicleKit
@testable import Freedom

/// Decision tables behind the node indicator ring and the
/// light-client menu rows. Pure — no views, no engines.
final class NodeSegmentStateTests: XCTestCase {
    private func chain(
        ready: Bool, paused: Bool = false, beaconPeers: Int = 0, snapPeers: Int? = nil
    ) -> MyotisChainStatus {
        var status = MyotisChainStatus()
        status.running = true
        status.paused = paused
        status.beaconState = ready ? "SYNCED" : "SYNCING"
        status.peerCount = beaconPeers
        status.snapPeers = snapPeers ?? (ready ? 1 : 0)
        return status
    }

    // MARK: - Segment mapping

    func testSwarmSegments() {
        XCTAssertEqual(NodeSegmentState.fromSwarm(.idle, peerCount: 0), .off)
        XCTAssertEqual(NodeSegmentState.fromSwarm(.stopped, peerCount: 0), .off)
        XCTAssertEqual(NodeSegmentState.fromSwarm(.failed, peerCount: 0), .failed)
        XCTAssertEqual(NodeSegmentState.fromSwarm(.starting, peerCount: 0), .warming)
        XCTAssertEqual(NodeSegmentState.fromSwarm(.running, peerCount: 0), .warming)
        XCTAssertEqual(NodeSegmentState.fromSwarm(.running, peerCount: 12), .healthy)
    }

    func testIpfsSegments() {
        XCTAssertEqual(NodeSegmentState.fromIpfs(.stopped), .off)
        XCTAssertEqual(NodeSegmentState.fromIpfs(.failed), .failed)
        XCTAssertEqual(NodeSegmentState.fromIpfs(.starting), .warming)
        XCTAssertEqual(NodeSegmentState.fromIpfs(.running), .healthy)
    }

    func testMyotisChainSegments() {
        XCTAssertEqual(NodeSegmentState.fromMyotisChain(.idle, chain: nil), .off)
        XCTAssertEqual(NodeSegmentState.fromMyotisChain(.failed, chain: nil), .failed)
        XCTAssertEqual(NodeSegmentState.fromMyotisChain(.starting, chain: nil), .warming)
        // Running but not yet serving verified reads → warming, not healthy.
        XCTAssertEqual(
            NodeSegmentState.fromMyotisChain(.running, chain: chain(ready: false)), .warming
        )
        XCTAssertEqual(NodeSegmentState.fromMyotisChain(.running, chain: nil), .warming)
        XCTAssertEqual(
            NodeSegmentState.fromMyotisChain(.running, chain: chain(ready: true)), .healthy
        )
    }

    /// Deliberately-off must render neutral, never red — red is
    /// reserved for genuine failures so it stays a signal.
    func testOffIsNotFailed() {
        XCTAssertNotEqual(NodeSegmentState.off.color, NodeSegmentState.failed.color)
    }

    // MARK: - Menu row wording

    func testMenuLineStates() {
        XCTAssertEqual(MyotisMenuLine.state(nodeStatus: .idle, chain: nil), "Off")
        XCTAssertEqual(MyotisMenuLine.state(nodeStatus: .stopped, chain: nil), "Off")
        XCTAssertEqual(MyotisMenuLine.state(nodeStatus: .failed, chain: nil), "Failed")
        XCTAssertEqual(MyotisMenuLine.state(nodeStatus: .starting, chain: nil), "Starting")
        XCTAssertEqual(MyotisMenuLine.state(nodeStatus: .running, chain: nil), "Starting")
        XCTAssertEqual(
            MyotisMenuLine.state(nodeStatus: .running, chain: chain(ready: false)), "Syncing"
        )
        XCTAssertEqual(
            MyotisMenuLine.state(nodeStatus: .running, chain: chain(ready: true)), "Verified"
        )
        XCTAssertEqual(
            MyotisMenuLine.state(nodeStatus: .running, chain: chain(ready: false, paused: true)),
            "Paused"
        )
    }

    func testMenuRowShowsPeerSumWhenVerified() {
        // Beacon (CL libp2p) + state (EL snap) peers are disjoint
        // networks — the row shows their sum as the live status.
        XCTAssertEqual(
            MyotisMenuLine.row(
                "Ethereum", nodeStatus: .running,
                chain: chain(ready: true, beaconPeers: 4, snapPeers: 5)
            ),
            "Ethereum · 9 peers"
        )
        XCTAssertEqual(
            MyotisMenuLine.row(
                "Gnosis", nodeStatus: .running,
                chain: chain(ready: true, beaconPeers: 0, snapPeers: 1)
            ),
            "Gnosis · 1 peer"
        )
    }

    func testMenuRowSyncingAppendsNonzeroPeers() {
        XCTAssertEqual(
            MyotisMenuLine.row(
                "Ethereum", nodeStatus: .running,
                chain: chain(ready: false, beaconPeers: 3, snapPeers: 0)
            ),
            "Ethereum · Syncing · 3 peers"
        )
        // Zero peers while syncing: bare state word, no "0 peers" noise.
        XCTAssertEqual(
            MyotisMenuLine.row(
                "Ethereum", nodeStatus: .running,
                chain: chain(ready: false, beaconPeers: 0, snapPeers: 0)
            ),
            "Ethereum · Syncing"
        )
    }

    func testMenuRowStateWordsForNonRunning() {
        XCTAssertEqual(
            MyotisMenuLine.row("Ethereum", nodeStatus: .idle, chain: nil),
            "Ethereum · Off"
        )
        XCTAssertEqual(
            MyotisMenuLine.row("Ethereum", nodeStatus: .failed, chain: nil),
            "Ethereum · Failed"
        )
        XCTAssertEqual(
            MyotisMenuLine.row(
                "Ethereum", nodeStatus: .running,
                chain: chain(ready: false, paused: true, beaconPeers: 3)
            ),
            "Ethereum · Paused"
        )
    }

    func testRadicleSegments() {
        // Same shape as Swarm: running without a peer can neither fetch
        // nor publish, so it reads as warming.
        XCTAssertEqual(NodeSegmentState.fromRadicle(.idle, peerCount: 0), .off)
        XCTAssertEqual(NodeSegmentState.fromRadicle(.stopping, peerCount: 3), .off)
        XCTAssertEqual(NodeSegmentState.fromRadicle(.stopped, peerCount: 0), .off)
        XCTAssertEqual(NodeSegmentState.fromRadicle(.failed, peerCount: 0), .failed)
        XCTAssertEqual(NodeSegmentState.fromRadicle(.starting, peerCount: 0), .warming)
        XCTAssertEqual(NodeSegmentState.fromRadicle(.running, peerCount: 0), .warming)
        XCTAssertEqual(NodeSegmentState.fromRadicle(.running, peerCount: 11), .healthy)
    }
}
