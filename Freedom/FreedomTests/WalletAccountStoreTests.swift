import XCTest
@testable import Freedom

/// Multiple software accounts under one seed: list, active account,
/// persistence, and what the vault signs as.
@MainActor
final class WalletAccountStoreTests: XCTestCase {
    private var service = ""
    private var defaults: UserDefaults!
    /// Main-actor fixtures live until teardown (runner abort otherwise).
    private var keep: [AnyObject] = []

    override func setUp() {
        service = "com.freedom.wallet.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: "WalletAccountStoreTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try VaultCrypto(service: service).wipe()
    }

    private func unlockedVault() async throws -> Vault {
        let vault = Vault(crypto: VaultCrypto(service: service, preferred: .deviceBound))
        try await vault.create(mnemonic: Mnemonic(phrase: "test test test test test test test test test test test junk"))
        keep.append(vault)
        return vault
    }

    private func store(_ vault: Vault) -> WalletAccountStore {
        let s = WalletAccountStore(vault: vault, defaults: defaults)
        keep.append(s)
        return s
    }

    func testStartsWithAccountOneAndAddsTheNextIndexUnderTheSeed() async throws {
        let vault = try await unlockedVault()
        let store = store(vault)
        XCTAssertEqual(store.accounts.map(\.index), [0])
        XCTAssertEqual(store.activeAccount.name, "Account 1")
        XCTAssertEqual(vault.activeAccountPath, .mainUser)
        let first = try vault.activeAddress()
        XCTAssertEqual(Hex.checksummed(first), "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")

        let savings = store.addAccount(name: " Savings ")
        XCTAssertEqual(savings.index, 1)
        XCTAssertEqual(savings.name, "Savings")
        XCTAssertEqual(store.activeIndex, 1)
        XCTAssertEqual(vault.activeAccountPath, .userAccount(1))
        let second = try vault.activeAddress()
        XCTAssertNotEqual(second.lowercased(), first.lowercased())
        XCTAssertEqual(second, try vault.signingKey(at: .userAccount(1)).ethereumAddress)
        XCTAssertEqual(store.address(of: savings), Hex.checksummed(second))
        XCTAssertEqual(try vault.signingAccount().address.toChecksumAddress(), Hex.checksummed(second))
        XCTAssertEqual(store.addAccount().name, "Account 3")
    }

    func testSwitchPostsAndPersistsRenamePersistsResetStartsOver() async throws {
        let vault = try await unlockedVault()
        let store = store(vault)
        store.addAccount(name: "B")
        let posted = expectation(forNotification: .walletActiveAccountChanged, object: nil) { note in
            note.userInfo?["index"] as? Int == 0
        }
        store.setActive(index: 0)
        await fulfillment(of: [posted], timeout: 1)
        XCTAssertEqual(vault.activeAccountPath, .mainUser)
        store.setActive(index: 42) // unknown: ignored
        XCTAssertEqual(store.activeIndex, 0)
        store.rename(index: 1, to: "  ")
        XCTAssertEqual(store.account(index: 1)?.name, "Account 2")
        store.rename(index: 1, to: "Trading")
        store.setActive(index: 1)

        let again = self.store(vault)
        XCTAssertEqual(again.accounts.map(\.name), ["Account 1", "Trading"])
        XCTAssertEqual(again.activeIndex, 1)
        XCTAssertEqual(vault.activeAccountPath, .userAccount(1))

        again.reset()
        XCTAssertEqual(again.accounts.map(\.index), [0])
        XCTAssertEqual(again.activeIndex, 0)
        XCTAssertEqual(vault.activeAccountPath, .mainUser)
    }
}
