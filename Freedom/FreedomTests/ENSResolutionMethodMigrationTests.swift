import XCTest
@testable import Freedom

/// One-time `ensResolutionMethod` migration in `SettingsStore.init`.
/// Custom-RPC users are preserved on `.userConfigured`; everyone else
/// (including fresh installs) lands on `.colibri`. The migration must be
/// idempotent — a later user choice can't be clobbered on next launch.
///
/// Test methods are `async` so the `@MainActor SettingsStore` locals
/// deinit inline on the main actor — a synchronous `@MainActor` test
/// method deallocates them through the executor-hop shim, which aborts.
@MainActor
final class ENSResolutionMethodMigrationTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ENSMethodMigration-\(UUID().uuidString)")!
    }

    func testFreshInstallDefaultsToColibri() async {
        let store = SettingsStore(defaults: freshDefaults())
        XCTAssertEqual(store.ensResolutionMethod, .colibri)
    }

    func testLegacyCustomRpcUserPreserved() async {
        let defaults = freshDefaults()
        // Pre-existing install that had the legacy custom-RPC toggle on,
        // with no `ensResolutionMethod` key yet.
        defaults.set(true, forKey: "enableEnsCustomRpc")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.ensResolutionMethod, .userConfigured)
    }

    func testLegacyQuorumUserMovesToColibri() async {
        let defaults = freshDefaults()
        defaults.set(false, forKey: "enableEnsCustomRpc")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.ensResolutionMethod, .colibri)
    }

    func testMigrationIsIdempotent() async {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "enableEnsCustomRpc")
        // First launch migrates custom-RPC → .userConfigured.
        _ = SettingsStore(defaults: defaults)
        // User then switches to quorum in settings.
        SettingsStore(defaults: defaults).ensResolutionMethod = .quorum
        // Next launch must respect that choice, not re-run the migration
        // back to .userConfigured off the still-true legacy flag.
        let relaunch = SettingsStore(defaults: defaults)
        XCTAssertEqual(relaunch.ensResolutionMethod, .quorum)
    }
}
