import XCTest
import MyotisKit
@testable import Freedom

/// Stale-anchor recovery policy: checkpoint record validation, the
/// external quorum (votes, replacement, conflicts) and the acquisition
/// pipeline's binding rules. Desktop `checkpoint-verifier*.test.js`
/// parity, offline — a scripted fetcher plays every endpoint.
final class MyotisCheckpointTests: XCTestCase {
    // MARK: - Fixtures

    static let net = MyotisCheckpointNetwork.mainnet
    /// A slot on an epoch boundary so `finalizedEpoch * 32 == slot`.
    static let slot: UInt64 = 10_000_000
    static let epoch: UInt64 = slot / 32
    static let root = "0x" + String(repeating: "ab", count: 32)
    static let otherRoot = "0x" + String(repeating: "cd", count: 32)
    /// Ten minutes (50 slots, > one epoch) after the slot, so a finality
    /// certificate one epoch later is still inside the wall clock.
    static let nowMs: Int64 = net.slotTimeMs(slot) + 10 * 60 * 1000

    /// Scripted fetcher: exact URL → body or error; unknown → unavailable.
    final class StubFetcher: MyotisCheckpointFetcher, @unchecked Sendable {
        var routes: [String: Result<Data, MyotisCheckpointError>] = [:]
        /// Exact URL → transport failure class (what the real fetcher throws).
        var transportFailures: [String: MyotisCheckpointTransportError] = [:]
        private let lock = NSLock()
        private(set) var calls: [String] = []
        private(set) var lastPostBody: Data?

        func fetch(_ request: URLRequest, limit: Int) async throws -> Data {
            let url = request.url!.absoluteString
            lock.withLock {
                calls.append(url)
                if request.httpMethod == "POST" { lastPostBody = request.httpBody }
            }
            if let transport = transportFailures[url] { throw transport }
            guard let route = routes[url] else { throw MyotisCheckpointError.unavailable }
            let data = try route.get()
            if data.count > limit { throw MyotisCheckpointError.unavailable }
            return data
        }

        func json(_ object: Any) -> Result<Data, MyotisCheckpointError> {
            .success(try! JSONSerialization.data(withJSONObject: object))
        }

        /// Script a fully agreeing authority for `slot`.
        func agree(_ source: String, slot: UInt64 = MyotisCheckpointTests.slot,
                   root: String = MyotisCheckpointTests.root, epoch: UInt64 = MyotisCheckpointTests.epoch,
                   finalizedRoot: String? = nil, optimistic: Bool? = nil,
                   blockFinalized: Any? = nil, blockOptimistic: Any? = nil, headStateFinalized: Any? = nil) {
            var block: [String: Any] = ["data": ["root": root]]
            var finality: [String: Any] = ["data": ["finalized": ["epoch": String(epoch), "root": finalizedRoot ?? root]]]
            if let optimistic {
                block["execution_optimistic"] = optimistic
                finality["execution_optimistic"] = optimistic
            }
            // Beacon API primitives on the requested BLOCK (PublicNode shape).
            if let blockFinalized { block["finalized"] = blockFinalized }
            if let blockOptimistic { block["execution_optimistic"] = blockOptimistic }
            // The head STATE's own top-level flag — never evidence for the block.
            if let headStateFinalized { finality["finalized"] = headStateFinalized }
            routes["\(source)/eth/v1/beacon/blocks/\(slot)/root"] = json(block)
            routes["\(source)/eth/v1/beacon/states/head/finality_checkpoints"] = json(finality)
        }
    }

    private func quorum(_ fetcher: StubFetcher, network: MyotisCheckpointNetwork = net) -> MyotisCheckpointQuorum {
        MyotisCheckpointQuorum(network: network, fetcher: fetcher, nowMs: { Self.nowMs })
    }

    private func record(
        root: String = root, slot: UInt64 = slot, verifiedAt: Int64 = nowMs,
        sources: [String] = ["https://mainnet.checkpoint.sigp.io", "https://beaconstate.ethstaker.cc"],
        finalizedEpoch: UInt64 = epoch, chainId: UInt64 = 1, network: String = "mainnet"
    ) -> MyotisCheckpointRecord {
        MyotisCheckpointRecord(
            chainId: chainId, network: network, root: root, slot: slot, verifiedAt: verifiedAt,
            sources: sources, finalizedEpoch: finalizedEpoch
        )
    }

    private func assertThrows(
        _ code: MyotisCheckpointError, file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let error as MyotisCheckpointError {
            XCTAssertEqual(error, code, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: - Record validation

    func testValidRecordPasses() throws {
        let validated = try record().validated(chainId: 1, nowMs: Self.nowMs)
        XCTAssertEqual(validated.root, Self.root)
        XCTAssertEqual(validated.schemaVersion, 2)
    }

    func testRecordRejectsWrongChainNetworkAndProvenance() async {
        await assertThrows(.mismatch) { _ = try record(chainId: 100).validated(chainId: 100, nowMs: Self.nowMs) }
        await assertThrows(.mismatch) { _ = try record(network: "gnosis").validated(chainId: 1, nowMs: Self.nowMs) }
        // Below threshold.
        await assertThrows(.mismatch) { _ = try record(sources: ["https://mainnet.checkpoint.sigp.io"]).validated(chainId: 1, nowMs: Self.nowMs) }
        // Above participants.
        await assertThrows(.mismatch) { _ = try record(sources: Array(Self.net.sources.prefix(4))).validated(chainId: 1, nowMs: Self.nowMs) }
        // Duplicate and foreign sources.
        await assertThrows(.mismatch) { _ = try record(sources: ["https://beaconstate.ethstaker.cc", "https://beaconstate.ethstaker.cc"]).validated(chainId: 1, nowMs: Self.nowMs) }
        await assertThrows(.mismatch) { _ = try record(sources: ["https://beaconstate.ethstaker.cc", "https://evil.example"]).validated(chainId: 1, nowMs: Self.nowMs) }
        // Zero root, epoch before slot, verifiedAt before slot time.
        await assertThrows(.mismatch) { _ = try record(root: "0x" + String(repeating: "0", count: 64)).validated(chainId: 1, nowMs: Self.nowMs) }
        await assertThrows(.mismatch) { _ = try record(finalizedEpoch: Self.epoch - 1).validated(chainId: 1, nowMs: Self.nowMs) }
        await assertThrows(.mismatch) { _ = try record(verifiedAt: Self.net.slotTimeMs(Self.slot) - 1).validated(chainId: 1, nowMs: Self.nowMs) }
    }

    func testRecordClockAndAgeRulesOnlyWhenFresh() async throws {
        // Slot in the future relative to the clock → clock.
        await assertThrows(.clock) { _ = try record().validated(chainId: 1, nowMs: Self.net.slotTimeMs(Self.slot) - 1000) }
        // verifiedAt after now → clock.
        await assertThrows(.clock) { _ = try record(verifiedAt: Self.nowMs + 1).validated(chainId: 1, nowMs: Self.nowMs) }
        // Older than one hour → stale …
        let late = Self.nowMs + MyotisCheckpointRecord.maxAgeMs + 1
        await assertThrows(.stale) { _ = try record().validated(chainId: 1, nowMs: late) }
        // … but a reloaded generation is judged by the engine, not by age.
        XCTAssertNoThrow(try record().validated(chainId: 1, nowMs: late, fresh: false))
    }

    // MARK: - Votes

    func testVoteRequiresFinalityEndorsement() async throws {
        let fetcher = StubFetcher()
        let source = Self.net.sources[0]
        fetcher.agree(source)
        let vote = try await quorum(fetcher).vote(source: source, slot: Self.slot)
        XCTAssertEqual(vote.root, Self.root)
        XCTAssertEqual(vote.finalizedEpoch, Self.epoch)

        // Block root alone (finality endpoint down) is never a vote.
        let lonely = StubFetcher()
        lonely.routes["\(source)/eth/v1/beacon/blocks/\(Self.slot)/root"] = lonely.json(["data": ["root": Self.root]])
        await assertThrows(.unavailable) { _ = try await quorum(lonely).vote(source: source, slot: Self.slot) }
    }

    func testVoteClassifiesOptimisticClockAndRace() async {
        let source = Self.net.sources[0]
        let optimistic = StubFetcher()
        optimistic.agree(source, optimistic: true)
        await assertThrows(.quorumConflict) { _ = try await quorum(optimistic).vote(source: source, slot: Self.slot) }

        // Finalized epoch ahead of the wall clock → clock.
        let ahead = StubFetcher()
        ahead.agree(source, epoch: Self.epoch + 100)
        await assertThrows(.clock) { _ = try await quorum(ahead).vote(source: source, slot: Self.slot) }

        // Finality not yet covering the slot → race.
        let behind = StubFetcher()
        behind.agree(source, epoch: Self.epoch - 1)
        await assertThrows(.race) { _ = try await quorum(behind).vote(source: source, slot: Self.slot) }
    }

    func testVoteWithDifferentFinalizedRootConsultsHistory() async throws {
        let source = Self.net.sources[0]
        // Finality moved on one epoch: the root must appear in the
        // authority's finalized-slot history exactly once.
        let later = StubFetcher()
        later.agree(source, epoch: Self.epoch + 1, finalizedRoot: Self.otherRoot)
        later.routes["\(source)/checkpointz/v1/beacon/slots"] = later.json(
            ["data": ["slots": [["slot": String(Self.slot), "block_root": Self.root]]]]
        )
        let vote = try await quorum(later).vote(source: source, slot: Self.slot)
        XCTAssertEqual(vote.root, Self.root)

        // Same epoch but a different finalized root → conflict.
        let conflict = StubFetcher()
        conflict.agree(source, finalizedRoot: Self.otherRoot)
        await assertThrows(.quorumConflict) { _ = try await quorum(conflict).vote(source: source, slot: Self.slot) }

        // History lists the slot with another root → conflict; missing → race.
        let contradict = StubFetcher()
        contradict.agree(source, epoch: Self.epoch + 1, finalizedRoot: Self.otherRoot)
        contradict.routes["\(source)/checkpointz/v1/beacon/slots"] = contradict.json(
            ["data": ["slots": [["slot": String(Self.slot), "block_root": Self.otherRoot]]]]
        )
        await assertThrows(.quorumConflict) { _ = try await quorum(contradict).vote(source: source, slot: Self.slot) }
        let missing = StubFetcher()
        missing.agree(source, epoch: Self.epoch + 1, finalizedRoot: Self.otherRoot)
        missing.routes["\(source)/checkpointz/v1/beacon/slots"] = missing.json(["data": ["slots": []]])
        await assertThrows(.race) { _ = try await quorum(missing).vote(source: source, slot: Self.slot) }
    }

    // MARK: - Quorum

    func testQuorumTwoOfThreeAgree() async throws {
        let fetcher = StubFetcher()
        fetcher.agree(Self.net.sources[0])
        fetcher.agree(Self.net.sources[1])
        // Third seat unreachable — still a quorum.
        let observation = try await quorum(fetcher).quorum(slot: Self.slot)
        XCTAssertEqual(observation.root, Self.root)
        XCTAssertEqual(observation.sources, [Self.net.sources[0], Self.net.sources[1]])
        XCTAssertEqual(observation.finalizedEpoch, Self.epoch)
    }

    func testQuorumReplacesUnavailableCandidatesInStableOrder() async throws {
        let fetcher = StubFetcher()
        // Seats 1–3 down; reserves 4 and 5 agree.
        fetcher.agree(Self.net.sources[3])
        fetcher.agree(Self.net.sources[4])
        let observation = try await quorum(fetcher).quorum(slot: Self.slot)
        XCTAssertEqual(observation.sources, [Self.net.sources[3], Self.net.sources[4]])
        // The three freed seats were refilled as one batch (4, 5, 6); the
        // last reserve was never consulted because the quorum settled.
        XCTAssertTrue(fetcher.calls.contains { $0.hasPrefix(Self.net.sources[5]) })
        XCTAssertFalse(fetcher.calls.contains { $0.hasPrefix(Self.net.sources[6]) })
    }

    func testQuorumTwoAgreeingVotesWinDespiteDissent() async throws {
        // Desktop rule: the first root group reaching the threshold wins;
        // one dissenting seat does not veto 2 of 3.
        let fetcher = StubFetcher()
        fetcher.agree(Self.net.sources[0])
        fetcher.agree(Self.net.sources[1], root: Self.otherRoot, finalizedRoot: Self.otherRoot)
        fetcher.agree(Self.net.sources[2])
        let observation = try await quorum(fetcher).quorum(slot: Self.slot)
        XCTAssertEqual(observation.root, Self.root)
        XCTAssertEqual(observation.sources, [Self.net.sources[0], Self.net.sources[2]])
    }

    func testQuorumDissentKeepsItsSeatAndConflicts() async {
        let fetcher = StubFetcher()
        fetcher.agree(Self.net.sources[0])
        fetcher.agree(Self.net.sources[1], root: Self.otherRoot, finalizedRoot: Self.otherRoot)
        // An optimistic answer is definitive dissent: it keeps its seat.
        fetcher.agree(Self.net.sources[2], optimistic: true)
        // Three occupied seats, no group at threshold, two distinct roots
        // → conflict; no search for agreeable reserves even though 4–7
        // would agree.
        for source in Self.net.sources[3...] { fetcher.agree(source) }
        await assertThrows(.quorumConflict) { _ = try await quorum(fetcher).quorum(slot: Self.slot) }
        XCTAssertFalse(fetcher.calls.contains { $0.hasPrefix(Self.net.sources[3]) })
    }

    func testQuorumUnavailableWhenBelowThreshold() async {
        let fetcher = StubFetcher()
        fetcher.agree(Self.net.sources[0])
        await assertThrows(.quorumUnavailable) { _ = try await quorum(fetcher).quorum(slot: Self.slot) }
        // Every candidate was tried once.
        for source in Self.net.sources {
            XCTAssertTrue(fetcher.calls.contains { $0.hasPrefix(source) }, source)
        }
    }

    func testQuorumAllClockIsClock() async {
        let fetcher = StubFetcher()
        for source in Self.net.sources { fetcher.agree(source, epoch: Self.epoch + 1000) }
        await assertThrows(.clock) { _ = try await quorum(fetcher).quorum(slot: Self.slot) }
    }

    // MARK: - Gnosis 2-of-3 with PublicNode's standard Beacon API (desktop PR #416)

    static let gnosis = MyotisCheckpointNetwork.gnosis
    static let gnosisSlot: UInt64 = 20_000_000
    static let gnosisEpoch = gnosisSlot / 16
    static let gnosisNowMs = gnosis.slotTimeMs(gnosisSlot) + 60_000
    static let checkpointz = gnosis.sources[0]
    static let dappnode = gnosis.sources[1]
    static let publicnode = gnosis.sources[2]

    private func gnosisQuorum(_ fetcher: StubFetcher) -> MyotisCheckpointQuorum {
        MyotisCheckpointQuorum(network: Self.gnosis, fetcher: fetcher, nowMs: { Self.gnosisNowMs })
    }

    /// Script PublicNode's shape: explicit block flags, no Checkpointz history.
    private func publicnodeAgrees(_ fetcher: StubFetcher, root: String = root, finalizedRoot: String? = nil) {
        fetcher.agree(Self.publicnode, slot: Self.gnosisSlot, root: root, epoch: Self.gnosisEpoch,
                      finalizedRoot: finalizedRoot, blockFinalized: true, blockOptimistic: false)
    }

    func testGnosisPolicyIsThreeIndependentOperatorsTwoMustAgree() {
        XCTAssertEqual(Self.gnosis.sources, [
            "https://checkpoint.gnosischain.com",
            "https://checkpoint-sync-gnosis.dappnode.net",
            "https://gnosis-beacon-api.publicnode.com",
        ])
        XCTAssertEqual(Self.gnosis.participants, 3)
        XCTAssertEqual(Self.gnosis.threshold, 2)
        XCTAssertEqual(Self.gnosis.beaconSources, ["https://gnosis-beacon-api.publicnode.com"])
        XCTAssertEqual(MyotisCheckpointNetwork.mainnet.beaconSources, [])
        XCTAssertEqual(MyotisCheckpointNetwork.mainnet.threshold, 2)
        XCTAssertEqual(MyotisCheckpointNetwork.mainnet.participants, 3)
    }

    func testGnosisRecoversWithAnyOneProviderDown() async throws {
        for down in Self.gnosis.sources {
            let fetcher = StubFetcher()
            for source in Self.gnosis.sources where source != down {
                if source == Self.publicnode {
                    publicnodeAgrees(fetcher)
                } else {
                    fetcher.agree(source, slot: Self.gnosisSlot, epoch: Self.gnosisEpoch)
                }
            }
            let observation = try await gnosisQuorum(fetcher).quorum(slot: Self.gnosisSlot)
            XCTAssertEqual(observation.root, Self.root, "down: \(down)")
            XCTAssertEqual(Set(observation.sources), Set(Self.gnosis.sources).subtracting([down]), "down: \(down)")
        }
    }

    func testGnosisNeedsTwoUsableVotes() async {
        let fetcher = StubFetcher()
        fetcher.agree(Self.checkpointz, slot: Self.gnosisSlot, epoch: Self.gnosisEpoch)
        await assertThrows(.quorumUnavailable) { _ = try await gnosisQuorum(fetcher).quorum(slot: Self.gnosisSlot) }
        // A PublicNode answer WITHOUT its finality flags is not a second vote.
        fetcher.agree(Self.publicnode, slot: Self.gnosisSlot, epoch: Self.gnosisEpoch)
        await assertThrows(.quorumUnavailable) { _ = try await gnosisQuorum(fetcher).quorum(slot: Self.gnosisSlot) }
    }

    func testGnosisConflictingRootsStillConflict() async throws {
        // One vote per root and the third seat unavailable: conflict, never
        // a fallback to whichever root answered first.
        let fetcher = StubFetcher()
        fetcher.agree(Self.checkpointz, slot: Self.gnosisSlot, epoch: Self.gnosisEpoch)
        fetcher.agree(Self.dappnode, slot: Self.gnosisSlot, root: Self.otherRoot, epoch: Self.gnosisEpoch)
        await assertThrows(.quorumConflict) { _ = try await gnosisQuorum(fetcher).quorum(slot: Self.gnosisSlot) }
        // Two agreeing votes win despite the dissenter (existing rule):
        // PublicNode's endorsement decides it.
        publicnodeAgrees(fetcher)
        let observation = try await gnosisQuorum(fetcher).quorum(slot: Self.gnosisSlot)
        XCTAssertEqual(observation.root, Self.root)
        XCTAssertEqual(Set(observation.sources), [Self.checkpointz, Self.publicnode])
    }

    func testBeaconSourceVoteRequiresExplicitBlockFinality() async throws {
        // finalized: true + execution_optimistic: false on the BLOCK → a vote.
        let ok = StubFetcher()
        publicnodeAgrees(ok)
        let vote = try await gnosisQuorum(ok).vote(source: Self.publicnode, slot: Self.gnosisSlot)
        XCTAssertEqual(vote.root, Self.root)
        XCTAssertEqual(vote.finalizedEpoch, Self.gnosisEpoch)
        // Missing flags → not a vote (unavailable), never a verdict.
        let missing = StubFetcher()
        missing.agree(Self.publicnode, slot: Self.gnosisSlot, epoch: Self.gnosisEpoch)
        await assertThrows(.unavailable) { _ = try await self.gnosisQuorum(missing).vote(source: Self.publicnode, slot: Self.gnosisSlot) }
        // Only one of the two flags → not a vote.
        let half = StubFetcher()
        half.agree(Self.publicnode, slot: Self.gnosisSlot, epoch: Self.gnosisEpoch, blockFinalized: true)
        await assertThrows(.unavailable) { _ = try await self.gnosisQuorum(half).vote(source: Self.publicnode, slot: Self.gnosisSlot) }
        // Malformed flag → not a vote.
        let malformed = StubFetcher()
        malformed.agree(Self.publicnode, slot: Self.gnosisSlot, epoch: Self.gnosisEpoch, blockFinalized: "yes", blockOptimistic: false)
        await assertThrows(.unavailable) { _ = try await self.gnosisQuorum(malformed).vote(source: Self.publicnode, slot: Self.gnosisSlot) }
        // finalized: false on the block → the checkpoint is ahead of this authority (race).
        let unfinalized = StubFetcher()
        unfinalized.agree(Self.publicnode, slot: Self.gnosisSlot, epoch: Self.gnosisEpoch, blockFinalized: false, blockOptimistic: false)
        await assertThrows(.race) { _ = try await self.gnosisQuorum(unfinalized).vote(source: Self.publicnode, slot: Self.gnosisSlot) }
        // Optimistic execution → contradiction, as before.
        let optimistic = StubFetcher()
        optimistic.agree(Self.publicnode, slot: Self.gnosisSlot, epoch: Self.gnosisEpoch, blockFinalized: true, blockOptimistic: true)
        await assertThrows(.quorumConflict) { _ = try await self.gnosisQuorum(optimistic).vote(source: Self.publicnode, slot: Self.gnosisSlot) }
    }

    func testHeadStateTopLevelFinalizedFlagIsNotEvidenceForTheBlock() async throws {
        // PublicNode's head STATE response can say finalized:false at the
        // top level while data.finalized is correct; only the BLOCK's flag
        // decides the vote.
        let fetcher = StubFetcher()
        fetcher.agree(Self.publicnode, slot: Self.gnosisSlot, epoch: Self.gnosisEpoch,
                      blockFinalized: true, blockOptimistic: false, headStateFinalized: false)
        let vote = try await gnosisQuorum(fetcher).vote(source: Self.publicnode, slot: Self.gnosisSlot)
        XCTAssertEqual(vote.root, Self.root)
    }

    func testExplicitBlockFinalityEndorsesOlderCheckpointsWithoutHistory() async throws {
        // The requested block is older than the authority's current
        // finalized checkpoint (different finalized root, later epoch), so
        // the wall clock must be past that later epoch.
        let later: Int64 = Self.gnosis.slotTimeMs(Self.gnosisSlot) + 10 * 60 * 1000
        func gnosisQuorum(_ f: StubFetcher) -> MyotisCheckpointQuorum {
            MyotisCheckpointQuorum(network: Self.gnosis, fetcher: f, nowMs: { later })
        }
        let fetcher = StubFetcher()
        fetcher.agree(Self.publicnode, slot: Self.gnosisSlot, epoch: Self.gnosisEpoch + 2,
                      finalizedRoot: Self.otherRoot, blockFinalized: true, blockOptimistic: false)
        let vote = try await gnosisQuorum(fetcher).vote(source: Self.publicnode, slot: Self.gnosisSlot)
        XCTAssertEqual(vote.root, Self.root)
        XCTAssertEqual(vote.finalizedEpoch, Self.gnosisEpoch)
        XCTAssertFalse(fetcher.calls.contains { $0.contains("/checkpointz/") }, "PublicNode receives no Checkpointz request")
        // A Checkpointz authority that also sets the block flags is endorsed
        // the same way; without them it must consult its history (covered by
        // testVoteWithDifferentFinalizedRootConsultsHistory).
        let cz = StubFetcher()
        cz.agree(Self.checkpointz, slot: Self.gnosisSlot, epoch: Self.gnosisEpoch + 2,
                 finalizedRoot: Self.otherRoot, blockFinalized: true, blockOptimistic: false)
        _ = try await gnosisQuorum(cz).vote(source: Self.checkpointz, slot: Self.gnosisSlot)
        XCTAssertFalse(cz.calls.contains { $0.contains("/checkpointz/") })
        // Same-epoch contradiction still wins over the flag.
        let contradiction = StubFetcher()
        contradiction.agree(Self.publicnode, slot: Self.gnosisSlot, epoch: Self.gnosisEpoch,
                            finalizedRoot: Self.otherRoot, blockFinalized: true, blockOptimistic: false)
        await assertThrows(.quorumConflict) { _ = try await self.gnosisQuorum(contradiction).vote(source: Self.publicnode, slot: Self.gnosisSlot) }
    }

    func testSourceDiagnosticsAreAllowlistedBoundedAndNeverSettleAVote() async throws {
        let fetcher = StubFetcher()
        fetcher.agree(Self.checkpointz, slot: Self.gnosisSlot, epoch: Self.gnosisEpoch)
        publicnodeAgrees(fetcher)
        fetcher.transportFailures["\(Self.dappnode)/eth/v1/beacon/blocks/\(Self.gnosisSlot)/root"] =
            MyotisCheckpointTransportError(.http, httpStatus: 503)
        let seen = Locked<[MyotisCheckpointSourceDiagnostic]>([])
        let quorum = MyotisCheckpointQuorum(network: Self.gnosis, fetcher: fetcher, nowMs: { Self.gnosisNowMs }) { d in
            seen.mutate { $0.append(d) }
            // A misbehaving sink must not reach the vote.
            if d.source == Self.publicnode { fatalErrorFree() }
        }
        let observation = try await quorum.quorum(slot: Self.gnosisSlot)
        XCTAssertEqual(Set(observation.sources), [Self.checkpointz, Self.publicnode])
        let diagnostics = seen.value
        XCTAssertEqual(diagnostics.count, 3)
        let byHost = Dictionary(uniqueKeysWithValues: diagnostics.map { ($0.source, $0) })
        XCTAssertEqual(byHost[Self.checkpointz]?.outcome, "vote")
        XCTAssertEqual(byHost[Self.publicnode]?.outcome, "vote")
        let failed = try XCTUnwrap(byHost[Self.dappnode])
        XCTAssertEqual(failed.outcome, MyotisCheckpointError.unavailable.rawValue)
        XCTAssertEqual(failed.stage, .blockRoot)
        XCTAssertEqual(failed.failure, .http)
        XCTAssertEqual(failed.httpStatus, 503)
        XCTAssertEqual(failed.slot, Self.gnosisSlot)
        XCTAssertTrue(diagnostics.allSatisfy { $0.elapsedMs >= 0 && Self.gnosis.sources.contains($0.source) })
        // The log line carries only allow-listed fields — hostnames, never paths or bodies.
        XCTAssertEqual(failed.logLine, "source=checkpoint-sync-gnosis.dappnode.net slot=\(Self.gnosisSlot) outcome=CHECKPOINT_UNAVAILABLE 0ms stage=block-root failure=http status=503")
        // Bounded construction: an out-of-policy source or absurd timing is dropped.
        XCTAssertNil(MyotisCheckpointSourceDiagnostic(source: "https://evil.example", network: Self.gnosis, slot: 1, elapsedMs: 1, error: nil))
        XCTAssertNil(MyotisCheckpointSourceDiagnostic(source: Self.publicnode, network: Self.gnosis, slot: 1, elapsedMs: -1, error: nil))
        XCTAssertNil(MyotisCheckpointSourceDiagnostic(source: Self.publicnode, network: Self.gnosis, slot: 0, elapsedMs: 1, error: nil))
        // Timeout and invalid-JSON classes map through wrap() to unavailable.
        let timeout = MyotisCheckpointSourceDiagnostic(source: Self.publicnode, network: Self.gnosis, slot: 1, elapsedMs: 20_000,
            error: MyotisCheckpointStagedError(stage: .finality, underlying: MyotisCheckpointTransportError(.timeout)))
        XCTAssertEqual(timeout?.failure, .timeout)
        XCTAssertEqual(timeout?.stage, .finality)
        XCTAssertEqual(timeout?.outcome, "CHECKPOINT_UNAVAILABLE")
        XCTAssertEqual(MyotisCheckpointError.wrap(MyotisCheckpointStagedError(stage: .history, underlying: MyotisCheckpointTransportError(.invalidJSON))), .unavailable)
        XCTAssertEqual(MyotisCheckpointError.wrap(MyotisCheckpointStagedError(stage: .history, underlying: MyotisCheckpointError.quorumConflict)), .quorumConflict)
    }

    func testGnosisQuorumWithPublicNodeCannotBypassAnInvalidColibriProof() async {
        // Two agreeing authorities (one of them PublicNode) AND a verifier
        // that rejects the proof: quorum is necessary, not sufficient.
        let fetcher = StubFetcher()
        fetcher.agree(Self.checkpointz, slot: Self.gnosisSlot, epoch: Self.gnosisEpoch)
        publicnodeAgrees(fetcher)
        fetcher.routes[Self.gnosis.prover] = .success(Data("proof-bytes".utf8))
        let acquirer = MyotisCheckpointAcquirer(
            fetcher: fetcher, corroborator: StubCorroborator(slots: [Self.gnosisSlot], failure: .mismatch),
            nowMs: { Self.gnosisNowMs }
        )
        await assertThrows(.mismatch) { _ = try await acquirer.acquire(chainId: 100) }
    }

    // MARK: - Acquisition pipeline

    /// Scripted corroborator: asks `trust` for the given slots, then
    /// either returns the observations or fails like Colibri would.
    nonisolated struct StubCorroborator: MyotisCheckpointCorroborator {
        var proofVersion: Int = 3 * 65536
        var slots: [UInt64]
        var failure: MyotisCheckpointError?
        var proofSeen: (@Sendable (Data) -> Void)?

        func corroborate(
            network: MyotisCheckpointNetwork, proof: Data,
            trust: @escaping @concurrent @Sendable (UInt64) async throws -> MyotisCheckpointObservation
        ) async throws -> [MyotisCheckpointObservation] {
            proofSeen?(proof)
            var observations: [MyotisCheckpointObservation] = []
            for slot in slots { observations.append(try await trust(slot)) }
            if let failure { throw failure }
            return observations
        }
    }

    private func scriptedProver(_ fetcher: StubFetcher) {
        fetcher.routes[Self.net.prover] = .success(Data("proof-bytes".utf8))
    }

    func testAcquireBindsQuorumToTheSlotColibriAskedFor() async throws {
        let fetcher = StubFetcher()
        scriptedProver(fetcher)
        fetcher.agree(Self.net.sources[0])
        fetcher.agree(Self.net.sources[1])
        let seen = Locked<Data?>(nil)
        let acquirer = MyotisCheckpointAcquirer(
            fetcher: fetcher,
            corroborator: StubCorroborator(slots: [Self.slot], proofSeen: { seen.value = $0 }),
            nowMs: { Self.nowMs }
        )
        let record = try await acquirer.acquire(chainId: 1)
        XCTAssertEqual(record.slot, Self.slot)
        XCTAssertEqual(record.root, Self.root)
        XCTAssertEqual(record.sources.count, 2)
        XCTAssertEqual(record.verifiedAt, Self.nowMs)
        XCTAssertEqual(seen.value, Data("proof-bytes".utf8))
        // The prover request pins the proof format and asks for a zk proof.
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(fetcher.lastPostBody)) as? [String: Any]
        XCTAssertEqual(body?["method"] as? String, "eth_getBlockByNumber")
        XCTAssertEqual(body?["version"] as? Int, 3 * 65536)
        XCTAssertEqual(ColibriDiskStorage.proofRequestVersion, 3 * 65536, "tracks the pinned package version")
        XCTAssertEqual(body?["zk_proof"] as? Bool, true)
    }

    /// Two agreeing authorities that also endorse the previous epoch's
    /// checkpoint (`otherRoot` at `slot - 32`) through their history.
    private func twoSlotFetcher() -> StubFetcher {
        let fetcher = StubFetcher()
        scriptedProver(fetcher)
        for source in Self.net.sources.prefix(2) {
            fetcher.agree(source)
            fetcher.routes["\(source)/eth/v1/beacon/blocks/\(Self.slot - 32)/root"] = fetcher.json(["data": ["root": Self.otherRoot]])
            fetcher.routes["\(source)/checkpointz/v1/beacon/slots"] = fetcher.json(
                ["data": ["slots": [["slot": String(Self.slot - 32), "block_root": Self.otherRoot]]]]
            )
        }
        return fetcher
    }

    func testAcquireFailsClosedWithoutOrWithAmbiguousObservations() async {
        let fetcher = twoSlotFetcher()
        // A verifier that never consulted the quorum is unsupported.
        await assertThrows(.incompatible) {
            _ = try await MyotisCheckpointAcquirer(
                fetcher: fetcher, corroborator: StubCorroborator(slots: []), nowMs: { Self.nowMs }
            ).acquire(chainId: 1)
        }
        // Two different checkpoints consulted → the binding is ambiguous.
        await assertThrows(.incompatible) {
            _ = try await MyotisCheckpointAcquirer(
                fetcher: fetcher, corroborator: StubCorroborator(slots: [Self.slot, Self.slot - 32]),
                nowMs: { Self.nowMs }
            ).acquire(chainId: 1)
        }
        // The same checkpoint consulted twice is fine (memoized lookup).
        let fresh = twoSlotFetcher()
        let twice = MyotisCheckpointAcquirer(
            fetcher: fresh, corroborator: StubCorroborator(slots: [Self.slot, Self.slot]), nowMs: { Self.nowMs }
        )
        let record = try? await twice.acquire(chainId: 1)
        XCTAssertEqual(record?.slot, Self.slot)
        XCTAssertEqual(fresh.calls.filter { $0.hasSuffix("/blocks/\(Self.slot)/root") }.count, 3, "one lookup per seat, memoized across trust calls")
    }

    func testAcquireTransportFailureWinsOverVerifierVerdict() async {
        // Quorum unavailable inside the interception → the verifier's
        // resulting "mismatch" must not mask the outage.
        let fetcher = StubFetcher()
        scriptedProver(fetcher)
        await assertThrows(.quorumUnavailable) {
            _ = try await MyotisCheckpointAcquirer(
                fetcher: fetcher, corroborator: StubCorroborator(slots: [Self.slot], failure: .mismatch),
                nowMs: { Self.nowMs }
            ).acquire(chainId: 1)
        }
        // A prover outage is unavailable, before any verification.
        let noProver = StubFetcher()
        await assertThrows(.unavailable) {
            _ = try await MyotisCheckpointAcquirer(
                fetcher: noProver, corroborator: StubCorroborator(slots: [Self.slot]), nowMs: { Self.nowMs }
            ).acquire(chainId: 1)
        }
    }

    func testAcquireRejectsOldAndFutureCheckpoints() async {
        let fetcher = StubFetcher()
        scriptedProver(fetcher)
        fetcher.agree(Self.net.sources[0])
        fetcher.agree(Self.net.sources[1])
        let corroborator = StubCorroborator(slots: [Self.slot])
        await assertThrows(.stale) {
            _ = try await MyotisCheckpointAcquirer(
                fetcher: fetcher, corroborator: corroborator,
                nowMs: { Self.nowMs + MyotisCheckpointRecord.maxAgeMs + 1 }
            ).acquire(chainId: 1)
        }
        // Every authority's finality certificate is ahead of the device
        // clock → clock (desktop: only when ALL seats say so).
        let everyone = StubFetcher()
        scriptedProver(everyone)
        for source in Self.net.sources { everyone.agree(source) }
        await assertThrows(.clock) {
            _ = try await MyotisCheckpointAcquirer(
                fetcher: everyone, corroborator: corroborator,
                nowMs: { Self.net.slotTimeMs(Self.slot) - 60_000 }
            ).acquire(chainId: 1)
        }
    }

    func testAcquireVerifierStaleMapsToStale() async {
        let fetcher = StubFetcher()
        scriptedProver(fetcher)
        fetcher.agree(Self.net.sources[0])
        fetcher.agree(Self.net.sources[1])
        await assertThrows(.stale) {
            _ = try await MyotisCheckpointAcquirer(
                fetcher: fetcher, corroborator: StubCorroborator(slots: [Self.slot], failure: .stale),
                nowMs: { Self.nowMs }
            ).acquire(chainId: 1)
        }
    }

    // MARK: - Interception policy (app side)

    func testColibriInterceptorAcceptsOnlyTheBlockRootPath() {
        let source = "https://mainnet.checkpoint.sigp.io"
        let accept = { (url: String, method: String) in
            ColibriCheckpointCorroborator.acceptedSlot(url: url, method: method, type: nil, source: source)
        }
        let checkpointz = { (url: String, method: String) in
            ColibriCheckpointCorroborator.acceptedSlot(url: url, method: method, type: "checkpointz", source: source)
        }
        // 3.x binding shape: bare uri, typed checkpointz, lowercase method.
        XCTAssertEqual(checkpointz("eth/v1/beacon/blocks/30145344/root", "get"), 30_145_344)
        XCTAssertEqual(checkpointz("/eth/v1/beacon/blocks/1/root", "GET"), 1)
        XCTAssertNil(accept("eth/v1/beacon/blocks/1/root", "GET"), "untyped relative uri is refused")
        XCTAssertNil(checkpointz("https://evil.example/eth/v1/beacon/blocks/1/root", "GET"))
        XCTAssertNil(checkpointz("eth/v1/beacon/blocks/1/root?x", "GET"))
        XCTAssertNil(checkpointz("eth/v1/beacon/states/head/finality_checkpoints", "GET"))
        XCTAssertEqual(accept("\(source)/eth/v1/beacon/blocks/123/root", "GET"), 123)
        XCTAssertEqual(accept("\(source)/eth/v1/beacon/blocks/123/root", "get"), 123)
        XCTAssertNil(accept("\(source)/eth/v1/beacon/blocks/123/root", "POST"))
        XCTAssertNil(accept("\(source)/eth/v1/beacon/blocks/123/root?x=1", "GET"))
        XCTAssertNil(accept("\(source)/eth/v1/beacon/blocks/123/root#f", "GET"))
        XCTAssertNil(accept("\(source)/eth/v1/beacon/blocks/abc/root", "GET"))
        XCTAssertNil(accept("\(source)/eth/v1/beacon/states/head/finality_checkpoints", "GET"))
        XCTAssertNil(accept("https://evil.example/eth/v1/beacon/blocks/123/root", "GET"))
        XCTAssertNil(accept("\(source).evil.example/eth/v1/beacon/blocks/123/root", "GET"))
        XCTAssertNil(accept("\(source)/eth/v1/beacon/blocks/123/root/", "GET"))
        XCTAssertEqual(accept("\(source)//eth/v1/beacon/blocks/123/root", "GET"), 123, "binding join seam")
    }

    // MARK: - Hex helpers

    func testHexRootNormalizesAndRejectsZero() {
        XCTAssertEqual(MyotisHex.root("0X" + String(repeating: "AB", count: 32)), Self.root)
        XCTAssertEqual(MyotisHex.root(String(repeating: "ab", count: 32)), Self.root)
        XCTAssertNil(MyotisHex.root("0x" + String(repeating: "0", count: 64)))
        XCTAssertNil(MyotisHex.root("0x" + String(repeating: "ab", count: 31)))
        XCTAssertNil(MyotisHex.root("0x" + String(repeating: "zz", count: 32)))
        XCTAssertEqual(MyotisHex.uint("0x10"), 16)
        XCTAssertEqual(MyotisHex.uint("16"), 16)
        XCTAssertEqual(MyotisHex.uint(16), 16)
        XCTAssertNil(MyotisHex.uint(-1))
        XCTAssertNil(MyotisHex.uint("1.5"))
    }
}

/// Tiny lock box for capturing values from `@Sendable` closures.
/// A sink side effect that must not influence the quorum (sinks cannot throw in Swift; this stands in for desktop's throwing-listener case).
@Sendable func fatalErrorFree() {}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    /// Atomic read-modify-write (concurrent sinks).
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&stored) } }
}
