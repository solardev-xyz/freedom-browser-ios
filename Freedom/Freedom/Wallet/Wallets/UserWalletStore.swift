import Foundation
import Observation
import SwiftUI

/// One software wallet: a BIP-44 account index under the vault's seed
/// (`HDKey.Path.userAccount(index)`; index 0 is the Main Wallet) and the
/// name the user gave it. Hidden wallets stay in the list — the keys
/// are derived, so hiding is the only kind of "delete" there is — and
/// their index is never reused.
struct UserWallet: Codable, Identifiable, Equatable {
    let index: Int
    var name: String
    var hidden: Bool = false
    var id: Int { index }

    var isMain: Bool { index == 0 }

    static func defaultName(for index: Int) -> String {
        index == 0 ? "Main Wallet" : "Wallet \(index + 1)"
    }
}

/// The user's wallets and which one is active (desktop "multiple
/// accounts"). Every signer, address display and dapp grant reads the
/// active one through `Vault.activeWalletPath`; switching posts
/// `.activeUserWalletChanged` so connected dapps hear
/// `accountsChanged`. The list order is the display order (Main Wallet
/// pinned first); names, order, hidden flags and the active index
/// persist in UserDefaults; keys are derived, never stored.
@MainActor
@Observable
final class UserWalletStore {
    private(set) var wallets: [UserWallet]
    private(set) var activeIndex: Int

    @ObservationIgnored private let vault: Vault
    @ObservationIgnored private let defaults: UserDefaults

    init(vault: Vault, defaults: UserDefaults = .standard) {
        self.vault = vault
        self.defaults = defaults
        let stored: [UserWallet]
        if let data = defaults.data(forKey: WalletDefaults.userWallets),
           let decoded = try? JSONDecoder().decode([UserWallet].self, from: data), decoded.contains(where: \.isMain)
        {
            stored = decoded
        } else {
            stored = [UserWallet(index: 0, name: UserWallet.defaultName(for: 0))]
        }
        let active = defaults.integer(forKey: WalletDefaults.activeUserWalletIndex)
        let activeIndex = stored.contains { $0.index == active && !$0.hidden } ? active : 0
        self.wallets = Self.pinningMain(stored)
        self.activeIndex = activeIndex
        vault.activeWalletPath = .userAccount(activeIndex)
    }

    var activeWallet: UserWallet { wallets.first { $0.index == activeIndex } ?? wallets[0] }
    var visibleWallets: [UserWallet] { wallets.filter { !$0.hidden } }
    var hiddenWallets: [UserWallet] { wallets.filter(\.hidden) }

    func wallet(index: Int) -> UserWallet? { wallets.first { $0.index == index } }

    /// The wallet's address; nil while the vault is locked.
    func address(of wallet: UserWallet) -> String? {
        try? Hex.checksummed(vault.signingKey(at: .userAccount(wallet.index)).ethereumAddress)
    }

    /// The next never-used index under the seed (hidden ones count as
    /// used). The same seed yields the same wallets on desktop, in the
    /// same order.
    @discardableResult
    func addWallet(name: String? = nil) -> UserWallet {
        let index = (wallets.map(\.index).max() ?? -1) + 1
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let wallet = UserWallet(index: index, name: trimmed.isEmpty ? UserWallet.defaultName(for: index) : trimmed)
        wallets.append(wallet)
        persist()
        setActive(index: index)
        return wallet
    }

    func rename(index: Int, to name: String) {
        guard let i = wallets.firstIndex(where: { $0.index == index }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        wallets[i].name = trimmed.isEmpty ? UserWallet.defaultName(for: index) : trimmed
        persist()
    }

    /// Main Wallet can't be hidden; hiding the active wallet switches to
    /// Main Wallet first.
    func hide(index: Int) {
        guard index != 0, let i = wallets.firstIndex(where: { $0.index == index }), !wallets[i].hidden else { return }
        if index == activeIndex { setActive(index: 0) }
        wallets[i].hidden = true
        persist()
    }

    func unhide(index: Int) {
        guard let i = wallets.firstIndex(where: { $0.index == index }), wallets[i].hidden else { return }
        wallets[i].hidden = false
        persist()
    }

    /// Reorder the visible wallets as `List.onMove` reports; Main Wallet
    /// stays first whatever the drag said.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var visible = visibleWallets
        visible.move(fromOffsets: source, toOffset: destination)
        let hidden = hiddenWallets
        wallets = Self.pinningMain(visible + hidden)
        persist()
    }

    func setActive(index: Int) {
        guard let wallet = wallet(index: index), !wallet.hidden, index != activeIndex else { return }
        activeIndex = index
        defaults.set(index, forKey: WalletDefaults.activeUserWalletIndex)
        vault.activeWalletPath = .userAccount(index)
        NotificationCenter.default.post(name: .activeUserWalletChanged, object: nil, userInfo: ["index": index])
    }

    /// A new or wiped vault starts over with Main Wallet.
    func reset() {
        wallets = [UserWallet(index: 0, name: UserWallet.defaultName(for: 0))]
        activeIndex = 0
        defaults.set(0, forKey: WalletDefaults.activeUserWalletIndex)
        vault.activeWalletPath = .mainUser
        persist()
    }

    private static func pinningMain(_ list: [UserWallet]) -> [UserWallet] {
        guard let main = list.first(where: \.isMain) else { return list }
        return [main] + list.filter { !$0.isMain }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(wallets) { defaults.set(data, forKey: WalletDefaults.userWallets) }
    }
}
