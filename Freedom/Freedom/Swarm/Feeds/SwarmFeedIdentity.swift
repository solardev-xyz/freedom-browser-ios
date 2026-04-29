import Foundation
import SwiftData

/// User's choice of which key signs feeds for a given origin. Per
/// SWIP §8.6, immutable once set — flipping it would orphan existing
/// feeds (different signing key → different SOC ownership).
enum SwarmFeedIdentityMode: String, Codable {
    /// Per-origin publisher key derived at `m/44'/73406'/{i}'/0/0`.
    /// Never funded; cryptographically isolated from the user wallet.
    case appScoped = "app-scoped"
    /// Bee node's main wallet key (`m/44'/60'/0'/0/1`). Useful when a
    /// dapp needs feeds signed by a known funded identity.
    case beeWallet = "bee-wallet"
}

/// Per-origin feed publisher identity. Lives separately from
/// `SwarmPermission` because SWIP §"Disconnection" requires feed
/// identity to survive revocation. Mutate exclusively via
/// `SwarmFeedStore.setFeedIdentity`; direct field writes bypass the
/// immutability guard.
@Model
final class SwarmFeedIdentity {
    @Attribute(.unique) var origin: String
    var identityMode: SwarmFeedIdentityMode
    /// Allocated index for `appScoped` — feeds the BIP-32 derivation.
    /// `nil` for `beeWallet`.
    var publisherKeyIndex: Int?
    var grantedAt: Date

    init(
        origin: String,
        identityMode: SwarmFeedIdentityMode,
        publisherKeyIndex: Int? = nil,
        grantedAt: Date = .now
    ) {
        self.origin = origin
        self.identityMode = identityMode
        self.publisherKeyIndex = publisherKeyIndex
        self.grantedAt = grantedAt
    }
}

enum SwarmFeedIdentityError: Swift.Error, Equatable {
    /// `appScoped` row stored without an allocated index — only
    /// reachable via direct SwiftData mutation; `setFeedIdentity`
    /// always allocates one for app-scoped origins.
    case missingPublisherIndex
}

extension SwarmFeedIdentity {
    /// Resolves the secp256k1 private key bytes bee will recover for
    /// this origin's feed signatures. Throws `Vault.Error.notUnlocked`
    /// if the vault was locked between the sheet's unlock-strip and
    /// the bridge handler's call (rare but possible — auto-lock
    /// during a backgrounded sheet).
    @MainActor
    func signingKey(via vault: Vault) throws -> Data {
        switch identityMode {
        case .appScoped:
            guard let index = publisherKeyIndex else {
                throw SwarmFeedIdentityError.missingPublisherIndex
            }
            return try vault.signingKey(
                at: .publisherKey(originIndex: index)
            ).privateKey
        case .beeWallet:
            return try vault.signingKey(at: .beeWallet).privateKey
        }
    }
}
