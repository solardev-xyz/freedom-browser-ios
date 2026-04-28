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

        static let defaults = Limits(
            maxDataBytes: 10 * 1024 * 1024,
            maxFilesBytes: 50 * 1024 * 1024,
            maxFileCount: 100
        )
    }

    var asJSONDict: [String: Any] {
        [
            "specVersion": Self.specVersion,
            "canPublish": canPublish,
            "reason": reason ?? NSNull() as Any,
            "limits": [
                "maxDataBytes": limits.maxDataBytes,
                "maxFilesBytes": limits.maxFilesBytes,
                "maxFileCount": limits.maxFileCount,
            ],
        ]
    }
}
