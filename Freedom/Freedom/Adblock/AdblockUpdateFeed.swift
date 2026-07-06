import Foundation

/// Trust anchor for the Swarm-distributed filter-list update channel.
///
/// The publisher (`freedom-adblock-service`) writes a signed manifest to a
/// Swarm feed owned by a dedicated key. The client reads that feed by
/// (owner, topic) — hardcoded here — so it never has to trust a reference
/// handed to it, only this compiled-in anchor. Two independent checks gate an
/// update: the feed's Single-Owner-Chunk signature (owner = `feedOwnerAddress`,
/// verified by the embedded bee node) and the manifest's application-level
/// `sig` (signer = `manifestSigAddress`, verified in
/// `AdblockUpdateManifest`). Separating them gives key-rotation headroom.
///
/// `manifestSchema` / `feedTopicString` mirror `src/manifest.ts` in
/// freedom-adblock-service and `feed-config.js` in the desktop browser —
/// this trio is a cross-repo contract.
enum AdblockUpdateFeed {
    /// Kept in lockstep with freedom-adblock-service `MANIFEST_SCHEMA`.
    static let manifestSchema = 1
    static let feedTopicString = "freedom/adblock/lists/v1"

    /// bee feed topics are the keccak256 of the topic string (bee-js
    /// `Topic.fromString` parity), 64-char lowercase hex.
    static let feedTopicHex = FeedTopic.fromString(feedTopicString)

    // PLACEHOLDERS — filled once the production publisher key exists. Until
    // then `isTrustAnchorConfigured` is false and the update service stays
    // dormant, so the app ships on bundled lists (the permanent floor) with
    // no live updates. Do NOT enable the update path against a zero address.
    //
    // The env overrides let a dev/simulator build point at a test publisher's
    // feed without recompiling; production relies on the hardcoded constants.
    private static let zeroAddress = "0x0000000000000000000000000000000000000000"

    static var feedOwnerAddress: String {
        ProcessInfo.processInfo.environment["FREEDOM_ADBLOCK_FEED_OWNER"] ?? zeroAddress
    }

    static var manifestSigAddress: String {
        ProcessInfo.processInfo.environment["FREEDOM_ADBLOCK_SIG_ADDRESS"] ?? zeroAddress
    }

    /// Whether real publisher-key constants have been compiled in. The update
    /// service must check this and no-op while false.
    static var isTrustAnchorConfigured: Bool {
        feedOwnerAddress.lowercased() != zeroAddress
            && manifestSigAddress.lowercased() != zeroAddress
    }
}
