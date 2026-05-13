import XCTest
import Colibri
@testable import Freedom

/// Live ENS resolution through Colibri's verifier. Diagnoses whether the
/// `UR.resolve(...)` call shape the Step 1 smoke flagged ("Revert" from the
/// v1.1.24 binding) reproduces against the production `ColibriENSClient`
/// config, and surfaces which names resolve cleanly today.
///
/// Disabled by default; opt in via `TEST_RUNNER_COLIBRI_E2E=1` (same gate
/// as `ColibriSmokeTests`). Network-dependent.
@MainActor
final class ColibriENSClientTests: XCTestCase {
    private var storageDir: URL!
    private var settings: SettingsStore!

    override func setUp() async throws {
        try await super.setUp()
        if ProcessInfo.processInfo.environment["COLIBRI_E2E"] != "1" {
            throw XCTSkip("Set TEST_RUNNER_COLIBRI_E2E=1 to run live Colibri prover tests")
        }
        executionTimeAllowance = 60
        storageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("colibri-ens-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        ColibriDiskStorage.register(directory: storageDir)
        let defaults = UserDefaults(suiteName: "ColibriENSClientTests-\(UUID().uuidString)")!
        settings = SettingsStore(defaults: defaults)
        settings.ensResolutionMethod = .colibri
    }

    override func tearDown() async throws {
        StorageBridge.implementation = nil
        if let dir = storageDir { try? FileManager.default.removeItem(at: dir) }
        try await super.tearDown()
    }

    func testResolveVitalikContenthash() async throws {
        let result = try await callUR(name: "vitalik.eth", selector: UniversalResolverABI.contenthashSelector)
        XCTAssertFalse(result.resolvedData.isEmpty, "Expected non-empty proven contenthash bytes")
    }

    func testResolveSwarmitContenthash() async throws {
        let result = try await callUR(name: "swarmit.eth", selector: UniversalResolverABI.contenthashSelector)
        XCTAssertFalse(result.resolvedData.isEmpty, "Expected non-empty proven contenthash bytes")
    }

    func testResolveVitalikAddress() async throws {
        let result = try await callUR(name: "vitalik.eth", selector: UniversalResolverABI.addrSelector)
        XCTAssertFalse(result.resolvedData.isEmpty, "Expected non-empty proven addr() return")
    }

    private func callUR(name: String, selector: Data) async throws -> (resolvedData: Data, resolverAddress: Any) {
        let client = ColibriENSClient(settings: settings)
        let normalized = try name.ensNormalized()
        let dns = try ENSNameEncoding.dnsEncode(normalized)
        let inner = selector + ENSNameEncoding.namehash(normalized)
        let (data, resolver) = try await client.universalResolverCall(
            dnsEncodedName: dns, callData: inner
        )
        return (data, resolver)
    }
}
