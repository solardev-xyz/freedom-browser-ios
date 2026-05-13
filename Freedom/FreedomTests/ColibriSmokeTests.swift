import XCTest
import Colibri
@testable import Freedom

/// Live-prover smoke for the vendored Colibri Swift package. Disabled by
/// default; opt in via `TEST_RUNNER_COLIBRI_E2E=1`. The `TEST_RUNNER_`
/// prefix is required so xcodebuild forwards the env var into the
/// simulator test runner.
///
///   TEST_RUNNER_COLIBRI_E2E=1 xcodebuild test \
///     -project Freedom/Freedom.xcodeproj \
///     -scheme Freedom \
///     -destination 'id=<sim-udid>' \
///     -only-testing FreedomTests/ColibriSmokeTests
@MainActor
final class ColibriSmokeTests: XCTestCase {
    private var storageDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        if ProcessInfo.processInfo.environment["COLIBRI_E2E"] != "1" {
            throw XCTSkip("Set TEST_RUNNER_COLIBRI_E2E=1 to run live Colibri prover tests")
        }
        // Fail fast if the prover or fallback RPCs hang. Smoke is meant
        // to take well under 10s end-to-end on a warm bootstrap.
        executionTimeAllowance = 30
        storageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("colibri-smoke-\(UUID().uuidString)")
        ColibriDiskStorage.register(directory: storageDir)
    }

    override func tearDown() async throws {
        // Clear the global storage bridge first so any subsequent test that
        // touches Colibri code doesn't get silent write failures against
        // the about-to-be-deleted temp dir. The bridge's auto-init falls
        // back to a fresh DefaultFileStorage on next call.
        StorageBridge.implementation = nil
        if let dir = storageDir {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    func testProofableEthGetBalanceViaColibri() async throws {
        let client = makeClient()
        // Vitalik's address. Balance changes daily, so the test only
        // asserts a 0x-prefixed hex string comes back.
        let result = try await client.rpc(
            method: "eth_getBalance",
            params: "[\"0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045\",\"latest\"]"
        )
        guard let hex = result as? String, hex.hasPrefix("0x") else {
            return XCTFail("Expected 0x-prefixed hex balance, got \(type(of: result)) = \(result)")
        }
    }

    private func makeClient() -> Colibri {
        let client = Colibri()
        client.chainId = 1
        client.provers = ["https://mainnet1.colibri-proof.tech"]
        // Mirror desktop's `colibri-resolver.js` config: ZK sync-committee
        // bootstrap (avoids the checkpointz round-trip) + Pragmatic
        // Adaptive Privacy basic mode (call params stay off the prover).
        client.zkProof = true
        client.privacyMode = .basic
        return client
    }
}

