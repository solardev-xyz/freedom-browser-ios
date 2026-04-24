import XCTest
@testable import Freedom

@MainActor
final class VaultTests: XCTestCase {
    /// Unique Keychain namespace per test instance so each test starts with
    /// a guaranteed-empty namespace — no setUp wipe needed, no cross-test
    /// leakage, safe under parallel test execution.
    private var service: String = ""

    /// The device-bound path has no biometric gate and behaves identically
    /// across simulator and device — our workhorse for deterministic tests.
    /// Forces the deviceBound tier — no biometric, no iCloud dependency,
    /// behaves identically across simulator and device. Workhorse for the
    /// majority of tests. The `.cloudSynced` and `.protected` paths each
    /// have a dedicated test using their own prompter / fallback.
    private func makeCrypto() -> VaultCrypto {
        VaultCrypto(service: service, preferred: .deviceBound)
    }

    override func setUp() {
        service = "com.freedom.wallet.test.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        try VaultCrypto(service: service).wipe()
    }

    func testFreshVaultStartsEmpty() async throws {
        let v = Vault(crypto: makeCrypto())
        XCTAssertEqual(v.state, .empty)
        XCTAssertNil(v.securityLevel)
    }

    func testCreateUnlocksAndPersistsDeviceBound() async throws {
        let mnemonic = try Mnemonic(phrase: "test test test test test test test test test test test junk")
        let v = Vault(crypto: makeCrypto())
        try await v.create(mnemonic: mnemonic)
        XCTAssertEqual(v.state, .unlocked)
        XCTAssertEqual(v.securityLevel, .deviceBound)

        let v2 = Vault(crypto: makeCrypto())
        XCTAssertEqual(v2.state, .locked)
        XCTAssertEqual(v2.securityLevel, .deviceBound)
    }

    func testUnlockRestoresSigningCapability() async throws {
        let mnemonic = try Mnemonic(phrase: "test test test test test test test test test test test junk")
        try await Vault(crypto: makeCrypto()).create(mnemonic: mnemonic)

        let reopened = Vault(crypto: makeCrypto())
        try await reopened.unlock()
        XCTAssertEqual(reopened.state, .unlocked)

        let key = try reopened.signingKey(at: .mainUser)
        XCTAssertEqual(
            try key.ethereumAddress,
            "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
        )
    }

    func testLockClearsSeed() async throws {
        let mnemonic = try Mnemonic(phrase: "test test test test test test test test test test test junk")
        let v = Vault(crypto: makeCrypto())
        try await v.create(mnemonic: mnemonic)
        XCTAssertEqual(v.state, .unlocked)

        v.lock()
        XCTAssertEqual(v.state, .locked)
        XCTAssertThrowsError(try v.signingKey(at: .mainUser))
    }

    func testCreateRefusesWhenVaultAlreadyExists() async throws {
        let mnemonic = Mnemonic()
        try await Vault(crypto: makeCrypto()).create(mnemonic: mnemonic)

        let second = Vault(crypto: makeCrypto())
        XCTAssertEqual(second.state, .locked)
        do {
            try await second.create(mnemonic: Mnemonic())
            XCTFail("expected alreadyExists")
        } catch Vault.Error.alreadyExists {
            // expected
        }
    }

    func testWipeReturnsToEmpty() async throws {
        let v = Vault(crypto: makeCrypto())
        try await v.create(mnemonic: Mnemonic())
        try await v.wipe()
        XCTAssertEqual(v.state, .empty)
        XCTAssertNil(v.securityLevel)

        let reopened = Vault(crypto: makeCrypto())
        XCTAssertEqual(reopened.state, .empty)
    }

    func testWipeBetweenCreationsAllowsFreshVault() async throws {
        let first = Mnemonic()
        let v = Vault(crypto: makeCrypto())
        try await v.create(mnemonic: first)
        try await v.wipe()

        let second = Mnemonic()
        try await v.create(mnemonic: second)
        XCTAssertEqual(v.state, .unlocked)
        // New seed ⇒ different account-0 address.
        let firstAddr = try HDKey(seed: first.seed()).derive(.mainUser).ethereumAddress
        let secondAddr = try v.signingKey(at: .mainUser).ethereumAddress
        XCTAssertNotEqual(firstAddr, secondAddr)
    }

    /// Exercises the `.cloudSynced` tier using an always-allow prompter —
    /// the real LAContext would hang waiting for user interaction. This
    /// test covers create + persist + unlock (with simulated biometric
    /// success) for the default production tier.
    func testCloudSyncedPathRoundTrips() async throws {
        let prompter = AlwaysAllowPrompter()
        let crypto = VaultCrypto(service: service, preferred: .cloudSynced, prompter: prompter)
        let mnemonic = try Mnemonic(phrase: "test test test test test test test test test test test junk")
        let v = Vault(crypto: crypto)
        try await v.create(mnemonic: mnemonic)
        XCTAssertEqual(v.securityLevel, .cloudSynced)

        let reopened = Vault(crypto: VaultCrypto(
            service: service,
            preferred: .cloudSynced,
            prompter: prompter
        ))
        XCTAssertEqual(reopened.securityLevel, .cloudSynced)
        try await reopened.unlock()
        XCTAssertEqual(
            try reopened.signingKey(at: .mainUser).ethereumAddress,
            "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
        )
    }

    /// `revealMnemonic` re-reads from storage (triggering a fresh biometric
    /// prompt on the cloudSynced tier) — we deliberately don't cache the
    /// words on Vault so this path always costs an explicit re-auth.
    func testRevealMnemonicReturnsStoredPhrase() async throws {
        let mnemonic = try Mnemonic(phrase: "test test test test test test test test test test test junk")
        let v = Vault(crypto: makeCrypto())
        try await v.create(mnemonic: mnemonic)
        let revealed = try await v.revealMnemonic()
        XCTAssertEqual(revealed.words, mnemonic.words)
    }

    /// When the prompter says auth isn't available (no passcode / biometric),
    /// the create path must fall back to `.deviceBound` rather than silently
    /// storing a plaintext DEK in iCloud Keychain.
    func testCloudSyncedFallsBackWhenPrompterUnavailable() async throws {
        let crypto = VaultCrypto(service: service, preferred: .cloudSynced, prompter: NeverPrompter())
        let v = Vault(crypto: crypto)
        try await v.create(mnemonic: Mnemonic())
        XCTAssertEqual(v.securityLevel, .deviceBound)
    }

    /// The only test that exercises the real SE path. On simulator, SE key
    /// creation may fail for reasons that don't reproduce on device — so we
    /// accept *either* level as success. The important invariant is that
    /// whatever was chosen at create-time round-trips on unlock.
    func testProtectedPathRoundTripsIfAvailable() async throws {
        let crypto = VaultCrypto(service: service, preferred: .protected)
        let mnemonic = try Mnemonic(phrase: "test test test test test test test test test test test junk")
        let v = Vault(crypto: crypto)
        try await v.create(mnemonic: mnemonic)
        let chosenLevel = v.securityLevel
        XCTAssertTrue(chosenLevel == .protected || chosenLevel == .deviceBound,
                      "unexpected level \(String(describing: chosenLevel))")

        let reopened = Vault(crypto: VaultCrypto(service: service, preferred: .protected))
        XCTAssertEqual(reopened.securityLevel, chosenLevel)
        try await reopened.unlock()
        XCTAssertEqual(
            try reopened.signingKey(at: .mainUser).ethereumAddress,
            "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
        )
    }

    /// Wipe of protected vault must delete the SE key too — otherwise the
    /// second create() would try to wrap a new DEK with the leftover key
    /// and roundtrip to it, producing silent divergence.
    func testWipeRemovesSEKeyAfterProtectedVault() async throws {
        let crypto = VaultCrypto(service: service, preferred: .protected)
        let v = Vault(crypto: crypto)
        try await v.create(mnemonic: Mnemonic())
        let firstLevel = v.securityLevel
        try await v.wipe()

        let reopened = Vault(crypto: VaultCrypto(service: service, preferred: .protected))
        XCTAssertEqual(reopened.state, .empty)
        try await reopened.create(mnemonic: Mnemonic())
        XCTAssertEqual(reopened.securityLevel, firstLevel)
        XCTAssertEqual(reopened.state, .unlocked)
    }
}
