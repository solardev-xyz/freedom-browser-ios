import Foundation

enum ENSContentCodec {
    case bzz
    case ipfs
    case ipns

    /// URL scheme the codec maps to. Used by handlers when building
    /// codec-mismatch error pages and when picking the expected codec
    /// for a given request scheme.
    var scheme: String {
        switch self {
        case .bzz: return "bzz"
        case .ipfs: return "ipfs"
        case .ipns: return "ipns"
        }
    }
}

struct ENSResolvedContent {
    let name: String
    let uri: URL
    /// Decoded content reference — the hex swarm reference for `.bzz`,
    /// the CID string (`Qm…` / `bafy…` / etc.) for `.ipfs`/`.ipns`.
    /// Carried alongside `uri` so a scheme handler can route a
    /// name-host URL (`bzz://swarm.eth/`) to the resolved content
    /// without re-parsing the URI.
    let contentRef: String
    let codec: ENSContentCodec
    let trust: ENSTrust
}

enum ENSNotFoundReason {
    case noResolver
    case noContenthash
    case emptyContenthash
    /// Resolver reverted with EIP-3668 OffchainLookup but the user has
    /// CCIP-Read disabled. Distinct from `.noContenthash` so we don't
    /// silently pin a verified "no content" verdict when the name does
    /// have content that just requires an offchain hop the user opted out of.
    case ccipDisabled
    /// `addr(bytes32)` returned the zero address — the name has a resolver
    /// but no Ethereum address record set. Distinct from `.noResolver`
    /// (no resolver at all) so the UI can show "name has no address" vs
    /// "name doesn't exist".
    case emptyAddress
}

struct ENSConflictGroup: Equatable {
    let resolvedData: Data?
    let reason: ENSNotFoundReason?
    let hosts: [String]
}

enum ENSResolutionError: Error {
    case invalidName
    case notFound(reason: ENSNotFoundReason, trust: ENSTrust)
    case unsupportedCodec(rawBytes: Data, trust: ENSTrust)
    case conflict(groups: [ENSConflictGroup], trust: ENSTrust)
    /// The anchor-corroboration step saw disagreement between providers
    /// on the block hash at the chosen number — a security signal the
    /// UI should surface distinctly from plain network failures.
    case anchorDisagreement(largestBucketSize: Int, total: Int, threshold: Int)
    case allProvidersErrored
    /// Resolution method is `.userConfigured` but the configured URL is
    /// missing/malformed or unreachable. Fail-closed — we don't silently
    /// fall back to the public pool, which would defeat the privacy
    /// intent of choosing a custom RPC.
    case customRpcFailed
    case notImplemented
}
