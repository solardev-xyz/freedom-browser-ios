import Foundation
import Observation

/// One software account: a BIP-44 account index under the vault's seed
/// (`HDKey.Path.userAccount(index)`, account 0 = the main user wallet)
/// and the name the user gave it.
struct WalletAccount: Codable, Identifiable, Equatable {
    let index: Int
    var name: String
    var id: Int { index }

    static func defaultName(for index: Int) -> String { "Account \(index + 1)" }
}

/// The wallet's accounts and which one is active (desktop "multiple
/// accounts"). Every signer, address display and dapp grant reads the
/// active one through `Vault.activeAccountPath`; switching posts
/// `.walletActiveAccountChanged` so connected dapps hear
/// `accountsChanged`. Names and the list persist in UserDefaults; the
/// keys themselves are derived, never stored.
@MainActor
@Observable
final class WalletAccountStore {
    private(set) var accounts: [WalletAccount]
    private(set) var activeIndex: Int

    @ObservationIgnored private let vault: Vault
    @ObservationIgnored private let defaults: UserDefaults

    init(vault: Vault, defaults: UserDefaults = .standard) {
        self.vault = vault
        self.defaults = defaults
        let stored: [WalletAccount]
        if let data = defaults.data(forKey: WalletDefaults.accounts),
           let decoded = try? JSONDecoder().decode([WalletAccount].self, from: data), !decoded.isEmpty
        {
            stored = decoded
        } else {
            stored = [WalletAccount(index: 0, name: WalletAccount.defaultName(for: 0))]
        }
        let active = defaults.integer(forKey: WalletDefaults.activeAccountIndex)
        let activeIndex = stored.contains { $0.index == active } ? active : stored[0].index
        self.accounts = stored
        self.activeIndex = activeIndex
        vault.activeAccountPath = .userAccount(activeIndex)
    }

    var activeAccount: WalletAccount {
        accounts.first { $0.index == activeIndex } ?? accounts[0]
    }

    func account(index: Int) -> WalletAccount? { accounts.first { $0.index == index } }

    /// The account's address; nil while the vault is locked.
    func address(of account: WalletAccount) -> String? {
        try? Hex.checksummed(vault.signingKey(at: .userAccount(account.index)).ethereumAddress)
    }

    /// The next unused account index under the seed. The same seed
    /// yields the same accounts on desktop, in the same order.
    @discardableResult
    func addAccount(name: String? = nil) -> WalletAccount {
        let index = (accounts.map(\.index).max() ?? -1) + 1
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let account = WalletAccount(index: index, name: trimmed.isEmpty ? WalletAccount.defaultName(for: index) : trimmed)
        accounts.append(account)
        persist()
        setActive(index: index)
        return account
    }

    func rename(index: Int, to name: String) {
        guard let i = accounts.firstIndex(where: { $0.index == index }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        accounts[i].name = trimmed.isEmpty ? WalletAccount.defaultName(for: index) : trimmed
        persist()
    }

    func setActive(index: Int) {
        guard accounts.contains(where: { $0.index == index }), index != activeIndex else { return }
        activeIndex = index
        defaults.set(index, forKey: WalletDefaults.activeAccountIndex)
        vault.activeAccountPath = .userAccount(index)
        NotificationCenter.default.post(name: .walletActiveAccountChanged, object: nil, userInfo: ["index": index])
    }

    /// A new or wiped vault starts over with account 1.
    func reset() {
        accounts = [WalletAccount(index: 0, name: WalletAccount.defaultName(for: 0))]
        activeIndex = 0
        defaults.set(0, forKey: WalletDefaults.activeAccountIndex)
        vault.activeAccountPath = .mainUser
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) { defaults.set(data, forKey: WalletDefaults.accounts) }
    }
}
