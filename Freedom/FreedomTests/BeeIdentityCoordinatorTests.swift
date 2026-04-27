import XCTest
import SwarmKit
@testable import Freedom

/// State machine, cancellation, and retry tests for the coordinator.
/// Injector logic is covered separately.
@MainActor
final class BeeIdentityCoordinatorTests: XCTestCase {
    private let dummySwarm = SwarmNode()
    private var settings: SettingsStore!

    override func setUp() async throws {
        try await super.setUp()
        // Per-test UUID suite so `revertInBackground` and `switchMode`
        // can't reach the user's real `beeNodeMode` /
        // `hasCompletedPublishSetup` (production was getting clobbered
        // back to ultralight by every test run).
        let defaults = UserDefaults(suiteName: "BeeIdentityCoordinatorTests-\(UUID().uuidString)")!
        settings = SettingsStore(defaults: defaults)
    }

    private func makeVault() -> Vault { Vault() }

    private func makeCoord(
        inject: @escaping BeeIdentityCoordinator.InjectionWork = { _, _, _ in },
        revert: @escaping BeeIdentityCoordinator.RevertWork = { _ in },
        restartForMode: @escaping BeeIdentityCoordinator.ModeChangeWork = { _, _ in }
    ) -> BeeIdentityCoordinator {
        BeeIdentityCoordinator(
            settings: settings,
            inject: inject,
            revert: revert,
            restartForMode: restartForMode
        )
    }

    // MARK: - Status transitions

    func testInjectTransitionsThroughSwappingToIdleOnSuccess() async throws {
        let coord = makeCoord()
        coord.injectInBackground(vault: makeVault(), swarm: dummySwarm)
        XCTAssertEqual(coord.status, .swapping)
        try await waitForStatus(coord, .idle)
    }

    func testInjectTransitionsToFailedOnError() async throws {
        let coord = makeCoord(inject: { _, _, _ in throw FakeError.boom })
        coord.injectInBackground(vault: makeVault(), swarm: dummySwarm)
        try await waitForFailed(coord)
        XCTAssertEqual(coord.failedMessage, FakeError.boom.localizedDescription)
    }

    func testRevertTransitionsThroughSwappingToIdleOnSuccess() async throws {
        let coord = makeCoord()
        coord.revertInBackground(swarm: dummySwarm)
        XCTAssertEqual(coord.status, .swapping)
        try await waitForStatus(coord, .idle)
    }

    func testRevertTransitionsToFailedOnError() async throws {
        let coord = makeCoord(revert: { _ in throw FakeError.boom })
        coord.revertInBackground(swarm: dummySwarm)
        try await waitForFailed(coord)
    }

    // MARK: - Dismiss

    func testDismissErrorClearsFailed() async throws {
        let coord = makeCoord(inject: { _, _, _ in throw FakeError.boom })
        XCTAssertNil(coord.failedMessage)
        coord.injectInBackground(vault: makeVault(), swarm: dummySwarm)
        try await waitForFailed(coord)
        XCTAssertEqual(coord.failedMessage, FakeError.boom.localizedDescription)
        coord.dismissError()
        XCTAssertEqual(coord.status, .idle)
        XCTAssertNil(coord.failedMessage)
    }

    // MARK: - Retry

    func testRetryReRunsLastInject() async throws {
        let injectCalls = ActorCallTracker()
        var attempt = 0
        let coord = makeCoord(
            inject: { _, _, _ in
                await injectCalls.increment()
                attempt += 1
                if attempt == 1 { throw FakeError.boom }
            },
            revert: { _ in XCTFail("should not be called") }
        )
        coord.injectInBackground(vault: makeVault(), swarm: dummySwarm)
        try await waitForFailed(coord)
        let firstCount = await injectCalls.value
        XCTAssertEqual(firstCount, 1)

        coord.retry()
        try await waitForStatus(coord, .idle)
        let retryCount = await injectCalls.value
        XCTAssertEqual(retryCount, 2)
    }

    func testRetryReRunsLastRevert() async throws {
        let revertCalls = ActorCallTracker()
        var attempt = 0
        let coord = makeCoord(
            inject: { _, _, _ in XCTFail("should not be called") },
            revert: { _ in
                await revertCalls.increment()
                attempt += 1
                if attempt == 1 { throw FakeError.boom }
            }
        )
        coord.revertInBackground(swarm: dummySwarm)
        try await waitForFailed(coord)
        let firstCount = await revertCalls.value
        XCTAssertEqual(firstCount, 1)

        coord.retry()
        try await waitForStatus(coord, .idle)
        let retryCount = await revertCalls.value
        XCTAssertEqual(retryCount, 2)
    }

    // MARK: - Mode change

    /// `switchMode` flips the persisted mode and routes through the
    /// `restartForMode` closure. No-ops when target mode equals current.
    func testSwitchModeFlipsSettingsAndRoutesToCoordinator() async throws {
        let calls = ActorCallTracker()
        settings.beeNodeMode = .ultraLight
        let coord = makeCoord(
            restartForMode: { _, _ in await calls.increment() }
        )
        coord.switchMode(to: .light, swarm: dummySwarm)
        try await waitForStatus(coord, .idle)
        let count = await calls.value
        XCTAssertEqual(count, 1)
        XCTAssertEqual(settings.beeNodeMode, .light)
    }

    func testSwitchModeNoOpsWhenAlreadyInTargetMode() async throws {
        let calls = ActorCallTracker()
        settings.beeNodeMode = .light
        let coord = makeCoord(
            restartForMode: { _, _ in await calls.increment() }
        )
        coord.switchMode(to: .light, swarm: dummySwarm)
        // Give the runloop a tick — should NOT trigger a restart.
        try await Task.sleep(nanoseconds: 50_000_000)
        let count = await calls.value
        XCTAssertEqual(count, 0)
    }

    // MARK: - Cancellation

    /// A new injectInBackground while one is already in flight cancels
    /// the prior. The test makes the first closure throw on resumption,
    /// so a *broken* cancellation would surface as `.failed`. With
    /// cancellation working correctly, the new task supersedes and end
    /// state is `.idle`. The asserted state therefore depends on the
    /// cancellation contract — it's not a tautology.
    func testNewInjectSupersedesPriorInFlight() async throws {
        let firstStarted = AsyncStream<Void>.makeStream()
        let firstSignal = expectation(description: "first started")
        let release = AsyncStream<Void>.makeStream()
        let invocations = ActorCallTracker()

        let coord = makeCoord(
            inject: { _, _, _ in
                let count = await invocations.value
                await invocations.increment()
                if count == 0 {
                    firstStarted.continuation.yield(())
                    for await _ in release.stream { break }
                    // First closure throws after release. Broken
                    // cancellation would propagate this to `.failed`.
                    throw FakeError.boom
                }
            }
        )

        coord.injectInBackground(vault: makeVault(), swarm: dummySwarm)
        Task {
            for await _ in firstStarted.stream {
                firstSignal.fulfill()
                break
            }
        }
        await fulfillment(of: [firstSignal], timeout: 1)

        coord.injectInBackground(vault: makeVault(), swarm: dummySwarm)
        release.continuation.yield(())
        release.continuation.finish()

        try await waitForStatus(coord, .idle)
        let total = await invocations.value
        XCTAssertEqual(total, 2)
    }

    // MARK: - Helpers

    private enum FakeError: Error, LocalizedError {
        case boom
        var errorDescription: String? { "boom" }
    }

    private func waitForStatus(
        _ coord: BeeIdentityCoordinator,
        _ target: BeeIdentityCoordinator.Status,
        timeout: TimeInterval = 2
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if coord.status == target { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for status \(target); current = \(coord.status)")
    }

    private func waitForFailed(
        _ coord: BeeIdentityCoordinator,
        timeout: TimeInterval = 2
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .failed = coord.status { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for .failed; current = \(coord.status)")
    }
}
