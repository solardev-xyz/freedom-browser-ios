import XCTest
import MyotisKit
@testable import Freedom

/// The recovery decision tables: reason mapping, retry ladder, finish
/// and mismatch checks, user-facing labels, and the ring/menu states
/// while recovering. Pure — no engine.
final class MyotisRecoveryTests: XCTestCase {
    private func status(
        beacon: String = "SYNCED", finalizedSlot: UInt64 = 0, finalizedRoot: String = "",
        snapPeers: Int = 1, serving: Int? = nil, elReader: Bool = true, hunting: Bool = false, lcHunting: Bool = false
    ) -> MyotisChainStatus {
        var s = MyotisChainStatus()
        s.running = true
        s.beaconState = beacon
        s.finalizedSlot = finalizedSlot
        s.finalizedRootHex = finalizedRoot
        s.snapPeers = snapPeers
        s.snapServingPeers = serving ?? snapPeers
        s.elReaderAvailable = elReader
        s.elHunting = hunting
        s.lcHunting = lcHunting
        return s
    }

    private var checkpoint: MyotisCheckpointRecord {
        MyotisCheckpointRecord(
            chainId: 1, network: "mainnet", root: MyotisCheckpointTests.root, slot: 1000,
            verifiedAt: 1, sources: [], finalizedEpoch: 32
        )
    }

    func testReasonMappingAndRetryability() {
        XCTAssertEqual(MyotisRecoveryReason(.quorumUnavailable), .quorumUnavailable)
        XCTAssertEqual(MyotisRecoveryReason(.race), .unavailable)
        XCTAssertEqual(MyotisRecoveryReason(.incompatible), .unsupported)
        XCTAssertEqual(MyotisRecoveryReason(.storageIO), .storageIO)
        for code in MyotisCheckpointError.allCases {
            let auto = [MyotisCheckpointError.unavailable, .quorumUnavailable, .race, .stale].contains(code)
            XCTAssertEqual(code.retryable, auto, code.rawValue)
        }
        XCTAssertFalse(MyotisRecoveryReason.unsupported.canRetry)
        XCTAssertFalse(MyotisRecoveryReason.installation.canRetry)
        XCTAssertTrue(MyotisRecoveryReason.quorumConflict.canRetry, "manual retry stays available")
        XCTAssertTrue(MyotisRecoveryReason.storage.offersRepair)
        XCTAssertTrue(MyotisRecoveryReason.stalled.restartsOwnedState)
        XCTAssertFalse(MyotisRecoveryReason.quorumUnavailable.restartsOwnedState)
    }

    func testRetryLadderIsFifteenSixtyThenEveryFiveMinutes() {
        // Desktop PR #416: transient outages never park recovery for good.
        XCTAssertEqual(MyotisRecoveryPolicy.retryDelay(afterAttempt: 1), 15)
        XCTAssertEqual(MyotisRecoveryPolicy.retryDelay(afterAttempt: 2), 60)
        XCTAssertEqual(MyotisRecoveryPolicy.retryDelay(afterAttempt: 3), 300)
        XCTAssertEqual(MyotisRecoveryPolicy.retryDelay(afterAttempt: 40), 300)
        XCTAssertNil(MyotisRecoveryPolicy.retryDelay(afterAttempt: 0))
        XCTAssertEqual(MyotisRecoveryPolicy.noticeSeconds, 60)
        // Manual retry while waiting for an automatic one, not only when blocked.
        let waiting = MyotisRecoveryState(phase: .waiting, reason: .quorumUnavailable, attempt: 3,
                                          nextRetryAt: Date(timeIntervalSinceNow: 300), canRetry: true)
        XCTAssertTrue(waiting.offersRetry)
        XCTAssertTrue(MyotisRecoveryState(phase: .blocked, reason: .clock, attempt: 1, canRetry: true).offersRetry)
        XCTAssertFalse(MyotisRecoveryState(phase: .checking, attempt: 1, canRetry: true).offersRetry)
        XCTAssertFalse(MyotisRecoveryState(phase: .waiting, reason: .unsupported, attempt: 1, canRetry: false).offersRetry)
        XCTAssertEqual(MyotisRecoveryPolicy.stallSeconds, 300)
    }

    func testCanFinishBindsFinalizedRootAtTheAnchorSlot() {
        let cp = checkpoint
        XCTAssertTrue(MyotisRecoveryPolicy.canFinish(status: status(), checkpoint: nil), "bundled: SYNCED is enough")
        XCTAssertFalse(MyotisRecoveryPolicy.canFinish(status: status(beacon: "CATCHING_UP"), checkpoint: nil))
        XCTAssertFalse(MyotisRecoveryPolicy.canFinish(status: status(finalizedSlot: 999, finalizedRoot: cp.root), checkpoint: cp))
        XCTAssertFalse(MyotisRecoveryPolicy.canFinish(status: status(finalizedSlot: 1000, finalizedRoot: ""), checkpoint: cp), "needs a root")
        XCTAssertTrue(MyotisRecoveryPolicy.canFinish(status: status(finalizedSlot: 1000, finalizedRoot: cp.root), checkpoint: cp))
        XCTAssertTrue(MyotisRecoveryPolicy.canFinish(status: status(finalizedSlot: 1000, finalizedRoot: String(cp.root.dropFirst(2)).uppercased()), checkpoint: cp), "unprefixed / upper hex")
        XCTAssertFalse(MyotisRecoveryPolicy.canFinish(status: status(finalizedSlot: 1000, finalizedRoot: MyotisCheckpointTests.otherRoot), checkpoint: cp))
        XCTAssertTrue(MyotisRecoveryPolicy.canFinish(status: status(finalizedSlot: 1032, finalizedRoot: MyotisCheckpointTests.otherRoot), checkpoint: cp), "past the anchor any root")
        XCTAssertTrue(MyotisRecoveryPolicy.isAnchorMismatch(status: status(finalizedSlot: 1000, finalizedRoot: MyotisCheckpointTests.otherRoot), checkpoint: cp))
        XCTAssertFalse(MyotisRecoveryPolicy.isAnchorMismatch(status: status(finalizedSlot: 1000, finalizedRoot: cp.root), checkpoint: cp))
        XCTAssertFalse(MyotisRecoveryPolicy.isAnchorMismatch(status: status(beacon: "STALE_ANCHOR", finalizedSlot: 1000, finalizedRoot: MyotisCheckpointTests.otherRoot), checkpoint: cp))
    }

    func testReadinessRequiresElReaderAndNoElHunt() {
        XCTAssertTrue(status().ready)
        XCTAssertFalse(status(elReader: false).ready)
        XCTAssertFalse(status(hunting: true).ready)
        // The LC hunt is NOT a gate (mainnet's LC pool is thin; the chain
        // serves fine while hunting for more light-client servers).
        XCTAssertTrue(status(lcHunting: true).ready)
        XCTAssertEqual(status(hunting: true).notServingReason, "EL hunting for a head")
        XCTAssertEqual(status(snapPeers: 0, elReader: false).notServingReason, "no state peer, EL reader down")
        XCTAssertFalse(status(snapPeers: 4, serving: 0).ready)
        XCTAssertEqual(status(snapPeers: 4, serving: 0).notServingReason, "no state peer at the verified head")
        XCTAssertEqual(status().notServingReason, "")
        XCTAssertEqual(status(beacon: "CATCHING_UP", snapPeers: 0).notServingReason, "")
        XCTAssertFalse(status(beacon: "STALE_ANCHOR").ready)
        XCTAssertTrue(status(beacon: "STALE_ANCHOR").isStaleAnchor)
    }

    func testStatusDecodeReadsAbi26Keys() {
        let json = """
        {"beaconState":"STALE_ANCHOR","currentPeriod":1825,"targetPeriod":1858,"wsBoundPeriods":13,
         "finalizedSlot":12345,"finalizedRootHex":"\(MyotisCheckpointTests.root.dropFirst(2))",
         "elReaderAvailable":true,"lcHunting":true,"elHunting":false,"running":true,"paused":false,"snapPeers":0,"snapServingPeers":0,"peerCount":2}
        """
        let decoded = MyotisChainStatus.decode(json)
        XCTAssertTrue(decoded.isStaleAnchor)
        XCTAssertEqual(decoded.currentPeriod, 1825)
        XCTAssertEqual(decoded.targetPeriod, 1858)
        XCTAssertEqual(decoded.wsBoundPeriods, 13)
        XCTAssertEqual(decoded.finalizedSlot, 12345)
        XCTAssertEqual(decoded.finalizedRootHex, String(MyotisCheckpointTests.root.dropFirst(2)))
        // Missing optional keys keep the permissive defaults (pre-26 shapes)
        // — except the ABI-31 serving count, which fails closed.
        let old = MyotisChainStatus.decode(#"{"beaconState":"SYNCED","running":true,"snapPeers":1}"#)
        XCTAssertTrue(old.elReaderAvailable)
        XCTAssertFalse(old.lcHunting)
        XCTAssertFalse(old.elHunting)
        XCTAssertFalse(old.ready)
        let serving = MyotisChainStatus.decode(#"{"beaconState":"SYNCED","running":true,"snapPeers":1,"snapServingPeers":1}"#)
        XCTAssertTrue(serving.ready)
        XCTAssertTrue(decoded.lcHunting)
        XCTAssertFalse(decoded.elHunting)
    }

    func testLabelsAndMessages() {
        let checking = MyotisRecoveryState(phase: .checking, attempt: 1, startedAt: Date(timeIntervalSinceNow: -61))
        XCTAssertEqual(checking.label, "Recovering")
        XCTAssertEqual(checking.message(), "Updating sync checkpoint…")
        XCTAssertTrue(checking.takingLonger())
        XCTAssertFalse(MyotisRecoveryState(phase: .checking, attempt: 1, startedAt: Date()).takingLonger())
        XCTAssertEqual(MyotisRecoveryState(phase: .restarting, attempt: 1).message(), "Checkpoint verified. Restarting sync…")
        XCTAssertEqual(MyotisRecoveryState(phase: .restarting, mode: .restart, attempt: 0).message(), "Restarting node…")
        let now = Date()
        let waiting = MyotisRecoveryState(phase: .waiting, reason: .quorumUnavailable, attempt: 1, nextRetryAt: now.addingTimeInterval(15))
        XCTAssertTrue(waiting.message(now: now).hasSuffix("Retrying in 15s…"))
        let blocked = MyotisRecoveryState(phase: .blocked, reason: .quorumConflict, attempt: 3, canRetry: true)
        XCTAssertEqual(blocked.label, "Sync paused")
        XCTAssertEqual(blocked.message(), MyotisCheckpointError.quorumConflict.message)
        XCTAssertFalse(blocked.takingLonger())
        XCTAssertEqual(MyotisRecoveryState(phase: .blocked, reason: .stalled, attempt: 0).label, "Syncing slowly")
    }

    func testMenuAndRingStatesWhileRecovering() {
        let chain = status()
        let checking = MyotisRecoveryState(phase: .checking, attempt: 1)
        let blocked = MyotisRecoveryState(phase: .blocked, reason: .storage, attempt: 3, canRetry: true)
        let stalled = MyotisRecoveryState(phase: .blocked, reason: .stalled, attempt: 0, canRetry: true)
        XCTAssertEqual(MyotisMenuLine.state(nodeStatus: .running, chain: chain, recovery: checking), "Recovering")
        XCTAssertEqual(MyotisMenuLine.state(nodeStatus: .running, chain: chain, recovery: blocked), "Sync paused")
        XCTAssertEqual(MyotisMenuLine.state(nodeStatus: .running, chain: chain, recovery: stalled), "Syncing slowly")
        XCTAssertEqual(MyotisMenuLine.state(nodeStatus: .running, chain: status(beacon: "STALE_ANCHOR")), "Recovering")
        XCTAssertEqual(MyotisMenuLine.state(nodeStatus: .running, chain: chain), "Verified")
        XCTAssertEqual(NodeSegmentState.fromMyotisChain(.running, chain: chain, recovery: checking), .warming)
        XCTAssertEqual(NodeSegmentState.fromMyotisChain(.running, chain: chain, recovery: blocked), .failed)
        XCTAssertEqual(NodeSegmentState.fromMyotisChain(.running, chain: chain, recovery: stalled), .warming)
        XCTAssertEqual(NodeSegmentState.fromMyotisChain(.running, chain: chain), .healthy)
    }

    @MainActor
    func testNodeReadinessGatesOnRecovery() {
        // A node that never started serves nothing and exposes no recovery.
        let node = MyotisNode()
        XCTAssertFalse(node.isReady(chainId: 1))
        XCTAssertNil(node.recovery[1])
        XCTAssertEqual(MyotisNode.expectedABI, 32)
        // The anchor marker contract was introduced at ABI 26 and is what
        // generations are stamped with (desktop parity: a constant, not the
        // engine ABI — bumping it would orphan every verified generation).
        XCTAssertEqual(MyotisGenerationStore.nativeCheckpointApi, 26)
        XCTAssertGreaterThanOrEqual(Int(MyotisNode.expectedABI), MyotisGenerationStore.nativeCheckpointApi)
        keep = node
    }

    /// Retained until teardown: synchronously dropping a @MainActor
    /// object inside a test body aborts in the back-deployed isolated
    /// deinit shim (see MyotisResolverTierTests).
    private var keep: MyotisNode?
}
