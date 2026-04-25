import Foundation

/// Well-known UserDefaults keys the wallet feature persists. Centralised
/// so any typo (`walletActiveChainID` vs `wallet.activeChainID` vs
/// `walletActiveChainId`) trips at compile-time instead of silently
/// fragmenting storage.
enum WalletDefaults {
    static let activeChainID = "walletActiveChainID"

    /// Single write path for the active chain. Use this from both the
    /// wallet UI's chain picker and the bridge's `wallet_switchEthereumChain`
    /// handler — guarantees exactly one `walletActiveChainChanged`
    /// notification per real change, regardless of which surface drove it.
    @MainActor
    static func setActiveChainID(_ id: Int) {
        let current = UserDefaults.standard.integer(forKey: activeChainID)
        guard current != id else { return }
        UserDefaults.standard.set(id, forKey: activeChainID)
        NotificationCenter.default.post(
            name: .walletActiveChainChanged,
            object: nil,
            userInfo: ["chainID": id]
        )
    }
}

extension Notification.Name {
    /// Posted when the user switches chains (via the wallet picker or a
    /// dapp's `wallet_switchEthereumChain`). `userInfo["chainID"]` carries
    /// the new Int chain ID. Bridge observers emit `chainChanged` to
    /// connected origins.
    static let walletActiveChainChanged = Notification.Name("walletActiveChainChanged")

    /// Posted when the user revokes a dapp's grant. `userInfo["origin"]`
    /// carries the `OriginIdentity.key` so observers can match affected tabs.
    static let walletPermissionRevoked = Notification.Name("walletPermissionRevoked")
}
