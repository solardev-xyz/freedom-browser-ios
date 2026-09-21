import XCTest
import MyotisKit
@testable import Freedom

/// Persisted sync-state generations: pointer + immutable anchor records,
/// append-only replacement, repair, and the native-marker consistency
/// check. Desktop `checkpoint-store.test.js` parity on a temp dir.
final class MyotisGenerationStoreTests: XCTestCase {
    private var root: URL!
    private var store: MyotisGenerationStore!
    private let nowMs = MyotisCheckpointTests.nowMs

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("myotis-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = MyotisGenerationStore(baseDir: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func checkpoint() -> MyotisCheckpointRecord {
        MyotisCheckpointRecord(
            chainId: 1, network: "mainnet", root: MyotisCheckpointTests.root,
            slot: MyotisCheckpointTests.slot, verifiedAt: nowMs,
            sources: ["https://mainnet.checkpoint.sigp.io", "https://beaconstate.ethstaker.cc"],
            finalizedEpoch: MyotisCheckpointTests.epoch
        )
    }

    func testFirstRunMintsBundledGenerationAndReloadsIt() throws {
        let first = try store.loadOrCreate(.mainnet, nowMs: nowMs)
        XCTAssertEqual(first.origin, .bundled)
        XCTAssertNil(first.checkpoint)
        XCTAssertTrue(first.directory.path.hasPrefix(root.appendingPathComponent("mainnet/verified-sync").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.directory.appendingPathComponent("anchor.json").path))
        let again = try store.loadOrCreate(.mainnet, nowMs: nowMs)
        XCTAssertEqual(again, first, "the pointer resumes the same generation")
        // Chains are independent.
        let gnosis = try store.loadOrCreate(.gnosis, nowMs: nowMs)
        XCTAssertNotEqual(gnosis.id, first.id)
        XCTAssertEqual(gnosis.chainId, 100)
    }

    func testLegacyEngineFilesAreLeftInPlace() throws {
        // v0.1.7 layout: engine files directly in <network>/.
        let chainDir = root.appendingPathComponent("mainnet", isDirectory: true)
        try FileManager.default.createDirectory(at: chainDir, withIntermediateDirectories: true)
        let legacy = chainDir.appendingPathComponent("sync-state.snapshot")
        try Data("old".utf8).write(to: legacy)
        let generation = try store.loadOrCreate(.mainnet, nowMs: nowMs)
        XCTAssertEqual(generation.origin, .bundled)
        XCTAssertEqual(try Data(contentsOf: legacy), Data("old".utf8), "retained, never edited")
        XCTAssertNotEqual(generation.directory, chainDir)
    }

    func testReplaceMintsVerifiedGenerationAndRetainsOld() throws {
        let bundled = try store.loadOrCreate(.mainnet, nowMs: nowMs)
        let verified = try store.replace(.mainnet, checkpoint: checkpoint(), nowMs: nowMs)
        XCTAssertEqual(verified.origin, .verified)
        XCTAssertEqual(verified.checkpoint, checkpoint())
        XCTAssertNotEqual(verified.id, bundled.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundled.directory.path), "old generation retained")
        let reloaded = try store.loadOrCreate(.mainnet, nowMs: nowMs + 3 * MyotisCheckpointRecord.maxAgeMs)
        XCTAssertEqual(reloaded, verified, "reload ignores the 1 h max age — the engine judges saved state")
    }

    func testReplaceValidatesFreshness() {
        var stale = checkpoint()
        stale.verifiedAt = nowMs
        XCTAssertThrowsError(try store.replace(.mainnet, checkpoint: stale, nowMs: nowMs + MyotisCheckpointRecord.maxAgeMs + 1)) {
            XCTAssertEqual($0 as? MyotisCheckpointError, .stale)
        }
        XCTAssertThrowsError(try store.replace(.gnosis, checkpoint: checkpoint(), nowMs: nowMs)) {
            XCTAssertEqual($0 as? MyotisCheckpointError, .mismatch)
        }
    }

    func testCorruptPointerOrAnchorIsStorageFailure() throws {
        let generation = try store.loadOrCreate(.mainnet, nowMs: nowMs)
        let pointer = root.appendingPathComponent("mainnet/verified-sync.json")
        try Data("{not json".utf8).write(to: pointer)
        XCTAssertThrowsError(try store.loadOrCreate(.mainnet, nowMs: nowMs)) {
            XCTAssertEqual($0 as? MyotisCheckpointError, .storage)
        }
        // Pointer fine, anchor record from a different engine ABI.
        let good = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "chainId": 1, "generation": generation.id,
        ])
        try good.write(to: pointer)
        let anchorURL = generation.directory.appendingPathComponent("anchor.json")
        var anchor = try JSONSerialization.jsonObject(with: Data(contentsOf: anchorURL)) as! [String: Any]
        anchor["nativeCheckpointApi"] = 25
        try JSONSerialization.data(withJSONObject: anchor).write(to: anchorURL)
        XCTAssertThrowsError(try store.loadOrCreate(.mainnet, nowMs: nowMs)) {
            XCTAssertEqual($0 as? MyotisCheckpointError, .storage)
        }
        // Oversized records are refused, never parsed.
        try Data(repeating: 0x20, count: MyotisGenerationStore.maxRecordBytes + 1).write(to: pointer)
        XCTAssertThrowsError(try store.loadOrCreate(.mainnet, nowMs: nowMs)) {
            XCTAssertEqual($0 as? MyotisCheckpointError, .storage)
        }
    }

    func testRepairBacksUpPointerAndStartsBundled() throws {
        let verified = try store.replace(.mainnet, checkpoint: checkpoint(), nowMs: nowMs)
        let repaired = try store.repair(.mainnet)
        XCTAssertEqual(repaired.origin, .bundled)
        XCTAssertNotEqual(repaired.id, verified.id)
        let chainDir = root.appendingPathComponent("mainnet")
        let backups = try FileManager.default.contentsOfDirectory(atPath: chainDir.path)
            .filter { $0.hasPrefix("verified-sync-backup-") }
        XCTAssertEqual(backups.count, 1)
        let backup = try JSONSerialization.jsonObject(with: Data(contentsOf: chainDir.appendingPathComponent(backups[0]))) as? [String: Any]
        XCTAssertEqual(backup?["generation"] as? String, verified.id, "byte-for-byte old pointer")
        XCTAssertTrue(FileManager.default.fileExists(atPath: verified.directory.path), "old generation preserved")
    }

    func testNativeMarkerMustAgreeWithTheRecord() throws {
        let verified = try store.replace(.mainnet, checkpoint: checkpoint(), nowMs: nowMs)
        // Absent: legal before the first engine create.
        XCTAssertNoThrow(try store.checkNativeMarker(verified, network: .mainnet))
        let marker = verified.directory.appendingPathComponent(MyotisGenerationStore.nativeMarkerName(.mainnet))
        try JSONSerialization.data(withJSONObject: [
            "checkpointRoot": MyotisCheckpointTests.root, "checkpointSlot": MyotisCheckpointTests.slot,
        ]).write(to: marker)
        XCTAssertNoThrow(try store.checkNativeMarker(verified, network: .mainnet))
        // Disagreeing slot → storage.
        try JSONSerialization.data(withJSONObject: [
            "checkpointRoot": MyotisCheckpointTests.root, "checkpointSlot": MyotisCheckpointTests.slot + 1,
        ]).write(to: marker)
        XCTAssertThrowsError(try store.checkNativeMarker(verified, network: .mainnet)) {
            XCTAssertEqual($0 as? MyotisCheckpointError, .storage)
        }
        // Unreadable → storage.
        try Data("garbage".utf8).write(to: marker)
        XCTAssertThrowsError(try store.checkNativeMarker(verified, network: .mainnet))
        // A marker on a bundled generation is foreign state → storage.
        let bundled = try store.repair(.mainnet)
        try JSONSerialization.data(withJSONObject: [
            "checkpointRoot": MyotisCheckpointTests.root, "checkpointSlot": MyotisCheckpointTests.slot,
        ]).write(to: bundled.directory.appendingPathComponent(MyotisGenerationStore.nativeMarkerName(.mainnet)))
        XCTAssertThrowsError(try store.checkNativeMarker(bundled, network: .mainnet))
        // Gnosis uses the suffixed marker name.
        XCTAssertEqual(MyotisGenerationStore.nativeMarkerName(.gnosis), "sync-anchor-gnosis.json")
    }

    // MARK: - Peer cache inheritance (myotis #465)

    func testReplacedGenerationInheritsPeerCachesButNotSyncState() throws {
        let bundled = try store.loadOrCreate(.mainnet, nowMs: nowMs)
        let peers = Data("1.2.3.4\t30303\t0xab\t1\tsnapok\n".utf8)
        let clPeers = Data("cl-peer-list".utf8)
        try peers.write(to: bundled.directory.appendingPathComponent("peers.cache"))
        try clPeers.write(to: bundled.directory.appendingPathComponent("cl-peers.cache"))
        try Data("old sync state".utf8).write(to: bundled.directory.appendingPathComponent("sync-state.snapshot"))

        let verified = try store.replace(.mainnet, checkpoint: checkpoint(), nowMs: nowMs)
        XCTAssertNotEqual(verified.directory, bundled.directory)
        XCTAssertEqual(try Data(contentsOf: verified.directory.appendingPathComponent("peers.cache")), peers)
        XCTAssertEqual(try Data(contentsOf: verified.directory.appendingPathComponent("cl-peers.cache")), clPeers)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: verified.directory.appendingPathComponent("sync-state.snapshot").path),
            "sync state belongs to its anchor and is never carried over"
        )
        // The previous generation is untouched.
        XCTAssertEqual(try Data(contentsOf: bundled.directory.appendingPathComponent("peers.cache")), peers)
    }

    func testFirstGenerationInheritsLegacyPeerCachesPerNetwork() throws {
        // v0.1.7 layout kept the engine files in <network>/ — including the
        // caches, under the network-suffixed names on Gnosis.
        let gnosisDir = root.appendingPathComponent("gnosis", isDirectory: true)
        try FileManager.default.createDirectory(at: gnosisDir, withIntermediateDirectories: true)
        let peers = Data("5.6.7.8\t30303\t0xcd\t1\n".utf8)
        try peers.write(to: gnosisDir.appendingPathComponent("peers-gnosis.cache"))
        let generation = try store.loadOrCreate(.gnosis, nowMs: nowMs)
        XCTAssertEqual(try Data(contentsOf: generation.directory.appendingPathComponent("peers-gnosis.cache")), peers)
        XCTAssertEqual(try Data(contentsOf: gnosisDir.appendingPathComponent("peers-gnosis.cache")), peers, "legacy file retained")
        XCTAssertEqual(MyotisGenerationStore.peerCacheNames(.mainnet), ["peers.cache", "cl-peers.cache"])
        XCTAssertEqual(MyotisGenerationStore.peerCacheNames(.gnosis), ["peers-gnosis.cache", "cl-peers-gnosis.cache"])
    }

    func testRepairInheritsTheCurrentGenerationsPeerCaches() throws {
        let current = try store.loadOrCreate(.mainnet, nowMs: nowMs)
        let peers = Data("9.9.9.9\t30303\t0xef\t1\tsnapok\n".utf8)
        try peers.write(to: current.directory.appendingPathComponent("peers.cache"))
        let repaired = try store.repair(.mainnet)
        XCTAssertNotEqual(repaired.directory, current.directory)
        XCTAssertEqual(try Data(contentsOf: repaired.directory.appendingPathComponent("peers.cache")), peers)
    }

    func testMissingCachesLeaveTheNewGenerationCold() throws {
        let generation = try store.loadOrCreate(.mainnet, nowMs: nowMs)
        XCTAssertFalse(FileManager.default.fileExists(atPath: generation.directory.appendingPathComponent("peers.cache").path))
    }
}
