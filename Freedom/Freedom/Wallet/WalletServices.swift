import Foundation

/// Bundle of wallet collaborators threaded together through the app's
/// dependency tree (FreedomApp → TabStore → BrowserTab → EthereumBridge).
/// Keeps each constructor's parameter list shallow — adding a new wallet
/// service in M5.7 (e.g. ENSResolver-for-recipient-resolution) becomes a
/// one-field addition here instead of an N-place plumbing change.
@MainActor
struct WalletServices {
    let vault: Vault
    let chainRegistry: ChainRegistry
    let permissionStore: PermissionStore
    let autoApproveStore: AutoApproveStore
    let transactionService: TransactionService
    let ensResolver: ENSResolver
}
