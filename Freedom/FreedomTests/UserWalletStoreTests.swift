import XCTest
@testable import Freedom

/// Multiple wallets under one seed: list, active wallet, hide/show,
/// order, persistence, and what the vault signs as.
@MainActor
final class UserWalletStoreTests: XCTestCase {
    private var service = ""
    private var defaults: UserDefaults!
    /// Main-actor fixtures live until teardown (runner abort otherwise).
    private var keep: [AnyObject] = []

    override func setUp() {
        service = "com.freedom.wallet.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: "UserWalletStoreTests-\(UUID().uuidString)")
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

    private func store(_ vault: Vault) -> UserWalletStore {
        let s = UserWalletStore(vault: vault, defaults: defaults)
        keep.append(s)
        return s
    }

    func testStartsWithMainWalletAndAddsTheNextIndexUnderTheSeed() async throws {
        let vault = try await unlockedVault()
        let store = store(vault)
        XCTAssertEqual(store.wallets.map(\.index), [0])
        XCTAssertEqual(store.activeWallet.name, "Main Wallet")
        XCTAssertEqual(vault.activeWalletPath, .mainUser)
        let first = try vault.activeAddress()
        XCTAssertEqual(Hex.checksummed(first), "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")

        let savings = store.addWallet(name: " Savings ")
        XCTAssertEqual(savings.index, 1)
        XCTAssertEqual(savings.name, "Savings")
        XCTAssertEqual(store.activeIndex, 1)
        XCTAssertEqual(vault.activeWalletPath, .userAccount(1))
        let second = try vault.activeAddress()
        XCTAssertNotEqual(second.lowercased(), first.lowercased())
        XCTAssertEqual(second, try vault.signingKey(at: .userAccount(1)).ethereumAddress)
        XCTAssertEqual(store.address(of: savings), Hex.checksummed(second))
        XCTAssertEqual(try vault.signingAccount().address.toChecksumAddress(), Hex.checksummed(second))
        XCTAssertEqual(store.addWallet().name, "Wallet 3")
    }

    func testHideKeepsTheIndexSwitchesToMainAndShowRestores() async throws {
        let vault = try await unlockedVault()
        let store = store(vault)
        store.addWallet(name: "B")   // index 1, active
        store.hide(index: 0)         // Main Wallet can't be hidden
        XCTAssertEqual(store.hiddenWallets, [])
        store.hide(index: 1)
        XCTAssertEqual(store.activeIndex, 0)
        XCTAssertEqual(vault.activeWalletPath, .mainUser)
        XCTAssertEqual(store.visibleWallets.map(\.index), [0])
        XCTAssertEqual(store.hiddenWallets.map(\.index), [1])
        store.setActive(index: 1)    // hidden: ignored
        XCTAssertEqual(store.activeIndex, 0)
        XCTAssertEqual(store.addWallet().index, 2, "a hidden wallet's index is never reused")
        store.unhide(index: 1)
        XCTAssertEqual(store.visibleWallets.map(\.index), [0, 1, 2], "a re-shown wallet keeps its place")
    }

    func testMoveKeepsMainFirstAndPersistsWithNamesAndActive() async throws {
        let vault = try await unlockedVault()
        let store = store(vault)
        store.addWallet(name: "B"); store.addWallet(name: "C")   // [0, 1, 2], active 2
        store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)   // C dragged above Main
        XCTAssertEqual(store.visibleWallets.map(\.name), ["Main Wallet", "C", "B"])
        let posted = expectation(forNotification: .activeUserWalletChanged, object: nil) { note in
            note.userInfo?["index"] as? Int == 1
        }
        store.setActive(index: 1)
        await fulfillment(of: [posted], timeout: 1)
        store.rename(index: 1, to: "  ")
        XCTAssertEqual(store.wallet(index: 1)?.name, "Wallet 2")
        store.rename(index: 1, to: "Trading")

        let again = self.store(vault)
        XCTAssertEqual(again.wallets.map(\.name), ["Main Wallet", "C", "Trading"])
        XCTAssertEqual(again.activeIndex, 1)
        XCTAssertEqual(vault.activeWalletPath, .userAccount(1))

        again.reset()
        XCTAssertEqual(again.wallets.map(\.index), [0])
        XCTAssertEqual(again.activeIndex, 0)
        XCTAssertEqual(vault.activeWalletPath, .mainUser)
    }
}
