import Foundation

enum ENSContentCodec {
    case bzz
    case ipfs
    case ipns
}

struct ENSResolvedContent {
    let name: String
    let uri: URL
    let codec: ENSContentCodec
    let trust: ENSTrust
}

enum ENSNotFoundReason {
    case noResolver
    case noContenthash
    case emptyContenthash
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
    /// The resolver reverted with EIP-3668 OffchainLookup and the user has
    /// CCIP-Read enabled. We detect the revert but don't yet implement the
    /// gateway-hop retry loop; this signals the user that the name needs
    /// CCIP specifically rather than generic "all providers failed."
    case ccipNotImplemented
    case allProvidersErrored
    case notImplemented
}
