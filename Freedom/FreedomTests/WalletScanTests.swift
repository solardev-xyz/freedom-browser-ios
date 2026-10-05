import SwarmKit
import XCTest
@testable import Freedom

/// `/health.walletScan` (ant v0.5.59 #142) as the app reads it.
@MainActor
final class WalletScanTests: XCTestCase {
    private struct Health: Decodable { let walletScan: WalletScan? }

    private func decode(_ json: String) throws -> WalletScan? {
        try JSONDecoder().decode(Health.self, from: Data(json.utf8)).walletScan
    }

    func testScanningReportsProgress() throws {
        let scan = try XCTUnwrap(decode(#"{"status":"ok","walletScan":{"state":"scanning","from":100,"scannedThrough":150,"head":300}}"#))
        XCTAssertTrue(scan.isLooking)
        XCTAssertEqual(scan.progress ?? -1, 0.25, accuracy: 1e-9)
    }

    func testPendingHasNoBoundsYet() throws {
        let scan = try XCTUnwrap(decode(#"{"walletScan":{"state":"pending","from":null,"scannedThrough":null,"head":null}}"#))
        XCTAssertTrue(scan.isLooking)
        XCTAssertNil(scan.progress)
    }

    func testRetryingIsStillLooking() throws {
        let scan = try XCTUnwrap(decode(#"{"walletScan":{"state":"retrying","from":1,"scannedThrough":1,"head":9,"error":"rpc: <url> timed out"}}"#))
        XCTAssertTrue(scan.isLooking)
        XCTAssertTrue(scan.isRetrying)
    }

    /// Confirming means the batches are registered; only completeness is
    /// being confirmed, so the normal storage UI shows.
    func testConfirmingDoneAndUnknownShowTheNormalUI() throws {
        for state in ["confirming", "done", "something-new"] {
            let scan = try XCTUnwrap(decode(#"{"walletScan":{"state":"\#(state)"}}"#))
            XCTAssertFalse(scan.isLooking, state)
        }
        XCTAssertNil(try decode(#"{"status":"ok"}"#), "no field: no rediscovery runs")
    }

    // MARK: - Copy (desktop #534)

    func testMessageShowsAFlooredPercentCappedAt99() {
        XCTAssertEqual(WalletScanCopy.message(WalletScan(state: "pending")), "Looking for your existing storage…")
        XCTAssertEqual(WalletScanCopy.message(WalletScan(state: "scanning", from: 0, scannedThrough: 779, head: 1000)), "Looking for your existing storage… 77%")
        XCTAssertEqual(WalletScanCopy.message(WalletScan(state: "scanning", from: 0, scannedThrough: 1000, head: 1000)), "Looking for your existing storage… 99%")
    }

    func testRetryingAsksTheUserToWait() {
        let scan = WalletScan(state: "retrying", from: 0, scannedThrough: 10, head: 100, error: "rpc: <url> timed out")
        XCTAssertEqual(WalletScanCopy.message(scan), "The Swarm node couldn't finish looking for your existing storage and is trying again. Wait for it before you buy more.")
        XCTAssertEqual(WalletScanCopy.hint(scan), "Retrying the search for your existing storage")
    }

    func testOnlyShownWhileNoStorageIsUsable() {
        let scan = WalletScan(state: "scanning")
        XCTAssertNotNil(WalletScanCopy.looking(scan, hasUsableStorage: false))
        XCTAssertNil(WalletScanCopy.looking(scan, hasUsableStorage: true))
        XCTAssertNil(WalletScanCopy.looking(WalletScan(state: "confirming"), hasUsableStorage: false))
        XCTAssertNil(WalletScanCopy.looking(nil, hasUsableStorage: false))
    }

    func testProgressIsClamped() throws {
        let scan = WalletScan(state: "scanning", from: 10, scannedThrough: 50, head: 20)
        XCTAssertEqual(scan.progress, 1)
    }
}
