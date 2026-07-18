import Foundation

/// Result shape for `swarm_getCapabilities` — SWIP §"swarm_getCapabilities".
/// `reason` strings live alongside the JSON-RPC error reasons on
/// `SwarmRouter.ErrorPayload.Reason` so the same vocabulary appears
/// whether the dapp sees them in `result.reason` (here) or in
/// `error.data.reason` on a 4900 from a publish call.
struct SwarmCapabilities: Equatable {
    /// Pinned per the SWIP — bumped only when the wire format changes.
    static let specVersion = "1.0"

    let canPublish: Bool
    let reason: String?
    let limits: Limits

    /// SWIP §"Limits" recommended defaults. `Int` is fine — Swift Int is
    /// 64-bit on iOS, well above the 50 MB ceiling.
    struct Limits: Equatable {
        let maxDataBytes: Int
        let maxFilesBytes: Int
        let maxFileCount: Int
        /// Per-`files[].path` UTF-8-byte cap. The dominant tar
        /// implementations (this app, desktop Freedom, bee-js) use
        /// USTAR's 100-byte `name` field with no PAX extensions —
        /// advertising it lets dapps adapt rather than discover via
        /// silent rejection.
        let maxPathBytes: Int
        /// Per-`swarm_publishChunk` / `swarm_writeSingleOwnerChunk`
        /// payload cap. Fixed by the Swarm chunk protocol — the SWIP
        /// requires advertising exactly 4096.
        let maxChunkPayloadBytes: Int
        /// Messaging extension (SWIP messaging §"Limits"). Max PSS/GSOC
        /// payload — ant enforces `4096 − 3×32 = 4000` usable bytes
        /// after trojan/SOC framing; same value desktop advertises.
        let maxMessageBytes: Int
        /// Max PSS `targets` neighborhood-prefix length in bytes —
        /// ant's `MAX_TARGET_LEN` (bee API cap).
        let maxTargetDepth: Int
        /// Max concurrent subscriptions per origin. The node-wide
        /// lurker pool is separate (exhaustion → retryable 4900).
        let maxSubscriptions: Int

        static let defaults = Limits(
            maxDataBytes: 10 * 1024 * 1024,
            maxFilesBytes: 50 * 1024 * 1024,
            maxFileCount: 100,
            maxPathBytes: 100,
            maxChunkPayloadBytes: SwarmSOC.maxChunkPayloadSize,
            maxMessageBytes: 4000,
            maxTargetDepth: 3,
            maxSubscriptions: 32
        )
    }

    var asJSONDict: [String: Any] {
        [
            "specVersion": Self.specVersion,
            "canPublish": canPublish,
            "reason": reason ?? NSNull() as Any,
            // SWIP messaging extension §"Feature Detection" — MUST be
            // present before `swarm_requestAccess` (static capability
            // fact, not user data), so it isn't gated on node state.
            "features": ["messaging"],
            // Non-standard desktop-parity fields: which signing
            // identity modes this provider offers, and which optional
            // surfaces exist. Lets dapps feature-detect the signing /
            // chunk tier without a version sniff.
            "publisherIdentityModes": [
                SwarmFeedIdentityMode.appScoped.rawValue,
                SwarmFeedIdentityMode.beeWallet.rawValue,
            ],
            "extensions": [
                "publisherSigning": true,
            ],
            "limits": [
                "maxDataBytes": limits.maxDataBytes,
                "maxFilesBytes": limits.maxFilesBytes,
                "maxFileCount": limits.maxFileCount,
                "maxPathBytes": limits.maxPathBytes,
                "maxChunkPayloadBytes": limits.maxChunkPayloadBytes,
                "maxMessageBytes": limits.maxMessageBytes,
                "maxTargetDepth": limits.maxTargetDepth,
                "maxSubscriptions": limits.maxSubscriptions,
            ],
        ]
    }
}
