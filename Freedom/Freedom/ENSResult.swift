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

struct ENSConflictGroup {
    let resolvedData: Data?
    let reason: ENSNotFoundReason?
    let hosts: [String]
}

enum ENSResolutionError: Error {
    case invalidName
    case notFound(reason: ENSNotFoundReason, trust: ENSTrust)
    case unsupportedCodec(rawBytes: Data, trust: ENSTrust)
    case conflict(groups: [ENSConflictGroup], trust: ENSTrust)
    case allProvidersErrored
    case notImplemented
}
