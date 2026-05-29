import SwiftData
import XCTest
@testable import Freedom

/// One-time migration of the legacy `ensPublicRpcProviders` UserDefaults
/// list into the mainnet `ChainRecord`. Gated by the `chainStoreMigrated`
/// marker so a wipe-and-reseed scenario can't re-import a stale list over
/// a user's later in-store edits.
///
/// Each scenario needs distinct pre-`ChainStore.init` state (custom
/// settings, pre-flipped marker, etc.), so container + settings are
/// re-built per test rather than shared via `setUp`.
@MainActor
final class ChainStoreMigrationTests: XCTestCase {
    private var container: ModelContainer!
    private var settings: SettingsStore!

    override func tearDown() async throws {
        container = nil
        settings = nil
    }

    private func makeContainerAndSettings() throws {
        container = try inMemoryContainer(for: ChainRecord.self)
        settings = SettingsStore(
            defaults: UserDefaults(suiteName: "ChainStoreMigration-\(UUID().uuidString)")!
        )
    }

    func testFreshInstallSeedsDefaults() throws {
        try makeContainerAndSettings()
        let store = ChainStore(context: container.mainContext, settings: settings)
        XCTAssertEqual(
            store.rpcURLs(forChainID: Chain.mainnetID),
            SettingsStore.defaultPublicRpcProviders
        )
        XCTAssertTrue(settings.chainStoreMigrated)
    }

    func testCustomizedSettingsCarriesToMainnetRecord() throws {
        try makeContainerAndSettings()
        let customURLs = [
            "https://my-private-node.example/eth",
            "https://backup.example/eth",
        ]
        settings.ensPublicRpcProviders = customURLs

        let store = ChainStore(context: container.mainContext, settings: settings)
        XCTAssertEqual(store.rpcURLs(forChainID: Chain.mainnetID), customURLs)
        XCTAssertTrue(settings.chainStoreMigrated)
    }

    func testMigrationIsIdempotentAcrossRelaunch() throws {
        try makeContainerAndSettings()
        let customURLs = ["https://my-private-node.example/eth"]
        settings.ensPublicRpcProviders = customURLs

        // First launch: migration imports user's URLs into mainnet.
        let store1 = ChainStore(context: container.mainContext, settings: settings)
        XCTAssertEqual(store1.rpcURLs(forChainID: Chain.mainnetID), customURLs)
        // User narrows the mainnet list inside the store.
        store1.updateRPCURLs(forChainID: Chain.mainnetID, ["https://only.example/eth"])
        // Second relaunch — same SwiftData store + settings.
        let store2 = ChainStore(context: container.mainContext, settings: settings)
        // The migration must not re-run; the in-store edit wins.
        XCTAssertEqual(
            store2.rpcURLs(forChainID: Chain.mainnetID),
            ["https://only.example/eth"]
        )
    }

    func testEmptySettingsListFallsBackToDefaults() throws {
        // A user could clear all providers in the legacy RPC settings UI.
        // Migrating that `[]` as-is would leave mainnet with no providers
        // and break ENS / wallet RPC immediately on first launch.
        try makeContainerAndSettings()
        settings.ensPublicRpcProviders = []

        let store = ChainStore(context: container.mainContext, settings: settings)
        XCTAssertEqual(
            store.rpcURLs(forChainID: Chain.mainnetID),
            SettingsStore.defaultPublicRpcProviders
        )
        XCTAssertTrue(settings.chainStoreMigrated)
    }

    func testWipeAndReseedSkipsSettingsImport() throws {
        // Simulates: a previous launch ran the migration + the user later
        // customized the mainnet list inside the store. Then the SwiftData
        // backing got wiped (clean reinstall reusing UserDefaults, manual
        // file removal, etc.). On reseed, `ensPublicRpcProviders` is
        // stale — the marker flag is the signal that it's no longer
        // authoritative, so we fall back to the built-in defaults.
        try makeContainerAndSettings()
        settings.ensPublicRpcProviders = ["https://stale.example/eth"]
        settings.chainStoreMigrated = true

        let store = ChainStore(context: container.mainContext, settings: settings)
        XCTAssertEqual(
            store.rpcURLs(forChainID: Chain.mainnetID),
            SettingsStore.defaultPublicRpcProviders
        )
    }
}
