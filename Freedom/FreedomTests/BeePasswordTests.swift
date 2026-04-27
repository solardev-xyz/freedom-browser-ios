import XCTest
@testable import Freedom

/// `BeePassword` is the Keychain-backed per-install secret that gates the
/// Bee node's V3 keystore. Tests verify three contracts:
///   - first call generates and persists a password;
///   - subsequent calls return the same value (no rotation);
///   - `wipe()` clears it so the next call generates fresh.
///
/// Tests run against the real device Keychain (no in-memory fake) — the
/// surface area we care about is `KeychainItem`'s read/write/delete cycle,
/// which is shared with the vault and already exercised in production.
final class BeePasswordTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        // SKIPPED during M6 (Swarm publishing) development. These tests
        // share the production Keychain — wiping the BeePassword entry
        // here triggers the legacy-install migration on the next manual
        // smoke launch (`FreedomApp.startNodeIfNeeded`'s
        // `isLegacyInstall` branch), which calls `wipeAll` on the bee
        // data dir and orphans any on-chain chequebook for the test
        // wallet. Re-enable when M6 lands; the proper long-term fix is
        // either (a) parameterize `BeePassword` to use a `.test` account
        // here, or (b) mirror the password to the data dir (desktop
        // pattern). See WP-cleanup follow-up.
        try XCTSkipIf(
            true,
            "Skipped during M6 dev — wipes production BeePassword Keychain"
        )
        try BeePassword.wipe()
    }

    override func tearDown() async throws {
        try BeePassword.wipe()
        try await super.tearDown()
    }

    func testFirstCallGeneratesPersistentPassword() throws {
        let password = try BeePassword.loadOrCreate()
        XCTAssertEqual(password.count, 64)              // 32 bytes hex
        XCTAssertTrue(password.allSatisfy(\.isHexDigit))

        // `readExisting` must see the value `loadOrCreate` just wrote.
        let read = try BeePassword.readExisting()
        XCTAssertEqual(read, password)
    }

    func testSubsequentCallsReturnSameValue() throws {
        let first = try BeePassword.loadOrCreate()
        let second = try BeePassword.loadOrCreate()
        let third = try BeePassword.loadOrCreate()
        XCTAssertEqual(first, second)
        XCTAssertEqual(second, third)
    }

    func testReadExistingReturnsNilBeforeFirstCreate() throws {
        XCTAssertNil(try BeePassword.readExisting())
    }

    /// After wipe, the next `loadOrCreate` must mint a fresh password —
    /// not return the cleared one or fail because of a stale state.
    func testWipeClearsPassword() throws {
        let original = try BeePassword.loadOrCreate()
        try BeePassword.wipe()
        XCTAssertNil(try BeePassword.readExisting())

        let regenerated = try BeePassword.loadOrCreate()
        XCTAssertNotEqual(original, regenerated)
    }

    /// Two independent installs would each generate a unique password —
    /// approximated here by wiping between calls. This is the property
    /// that prevents one device's compromised keystore file from being
    /// readable on another device that happens to share the same vault.
    func testRegeneratedPasswordsAreUnique() throws {
        var seen = Set<String>()
        for _ in 0..<5 {
            try BeePassword.wipe()
            seen.insert(try BeePassword.loadOrCreate())
        }
        XCTAssertEqual(seen.count, 5)
    }
}
