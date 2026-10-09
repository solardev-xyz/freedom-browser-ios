import SwarmKit
import XCTest
@testable import Freedom

/// The Swarm chunk cache settings over ant's C calls (v0.5.60).
@MainActor
final class SwarmCacheTests: XCTestCase {
    private let mib: UInt64 = 1 << 20

    func testStatusDecodesAntsJSON() throws {
        let json = #"{"disk_enabled":true,"used_bytes":88080384,"capacity_bytes":268435456,"chunks":21504,"pinned_bytes":12582912,"pinned_chunks":3072,"file_bytes":104857600,"memory_chunks":812,"memory_capacity_chunks":8192}"#
        let status = try JSONDecoder().decode(SwarmCacheStatus.self, from: Data(json.utf8))
        XCTAssertTrue(status.diskEnabled)
        XCTAssertEqual(status.usedBytes, 84 * mib)
        XCTAssertEqual(status.capacityBytes, 256 * mib)
        XCTAssertEqual(SwarmCache.summary(status), "\(SwarmCache.format(84 * mib)) of \(SwarmCache.format(256 * mib)) · \(SwarmCache.format(12 * mib)) pinned")
    }

    func testOnlyOfferedSizesReachAnt() {
        XCTAssertEqual(SwarmCache.sanitized(Int(2048 * mib)), 2048 * mib)
        XCTAssertEqual(SwarmCache.sanitized(Int(128 * mib)), SwarmCache.defaultBytes, "an older build's size that is no longer offered")
        XCTAssertEqual(SwarmCache.sanitized(0), SwarmCache.defaultBytes)
        XCTAssertEqual(SwarmCache.defaultBytes, 1024 * mib)
        XCTAssertTrue(SwarmCache.sizes.allSatisfy { $0 >= 64 * mib && $0 <= 16 * 1024 * mib }, "inside ant's clamp")
        XCTAssertEqual(SwarmCache.sizes.map(SwarmCache.label), ["256 MB", "512 MB", "1 GB", "2 GB", "5 GB"])
    }

    func testInitConfigOnlyNamesWhatIsSet() {
        XCTAssertEqual(SwarmNode.initConfigJSON(cacheCapacityBytes: nil), "")
        XCTAssertEqual(SwarmNode.initConfigJSON(cacheCapacityBytes: 256 * mib), #"{"cache_capacity_bytes":268435456}"#)
    }

    func testAnOversizedFileIsShrunk() {
        func status(file: UInt64, cap: UInt64 = 256 << 20) -> SwarmCacheStatus {
            SwarmCacheStatus(diskEnabled: true, usedBytes: 0, capacityBytes: cap, pinnedBytes: 0, fileBytes: file)
        }
        XCTAssertTrue(SwarmCache.needsShrink(status(file: 842 * mib)), "the 842 MB file from the crash, against a 256 MiB cap")
        XCTAssertFalse(SwarmCache.needsShrink(status(file: 300 * mib)))
        XCTAssertFalse(SwarmCache.needsShrink(SwarmCacheStatus(diskEnabled: false, usedBytes: 0, capacityBytes: 0, pinnedBytes: 0, fileBytes: 0)))
    }

    /// Async: a main-actor object freed at the end of a synchronous test
    /// trips the runner's malloc check.
    func testSettingDefaultsToTheSmallSize() async {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "SwarmCache-\(UUID().uuidString)")!)
        XCTAssertEqual(UInt64(settings.swarmCacheCapacityBytes), SwarmCache.defaultBytes)
    }
}
