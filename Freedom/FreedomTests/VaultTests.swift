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
    /// Forces the deviceBound tier — no biometric gate, no iCloud dependency,
    /// behaves identically on simulator and device. Workhorse for
    /// deterministic tests. `.cloudSynced` and `.protected` each have a
    /// dedicated tolerant test below.
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

    /// Exercises the real `.cloudSynced` path — the v1 default. On simulator
    /// `.userPresence` ACL creation sometimes fails (no passcode enrolled),
    /// so accept either `.cloudSynced` or `.deviceBound`. Whichever was
    /// chosen at create-time must round-trip on unlock.
    func testCloudSyncedPathRoundTripsIfAvailable() async throws {
        let crypto = VaultCrypto(service: service, preferred: .cloudSynced)
        let mnemonic = try Mnemonic(phrase: "test test test test test test test test test test test junk")
        let v = Vault(crypto: crypto)
        try await v.create(mnemonic: mnemonic)
        let chosenLevel = v.securityLevel
        XCTAssertTrue(chosenLevel == .cloudSynced || chosenLevel == .deviceBound,
                      "unexpected level \(String(describing: chosenLevel))")

        let reopened = Vault(crypto: VaultCrypto(service: service, preferred: .cloudSynced))
        XCTAssertEqual(reopened.securityLevel, chosenLevel)
        try await reopened.unlock()
        XCTAssertEqual(
            try reopened.signingKey(at: .mainUser).ethereumAddress,
            "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
        )
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
