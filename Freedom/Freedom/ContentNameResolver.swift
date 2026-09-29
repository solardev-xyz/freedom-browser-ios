import Foundation

/// What a name resolves to for navigation: content the browser serves
/// under the name, or a plain web URL it navigates to (a Tezos Domains
/// `web:redirect_url` / HTTP `web:content_url`).
enum NameResolution {
    case content(ENSResolvedContent)
    case web(URL, trust: ENSTrust)
}

extension ENSResolving {
    /// Default for content-only resolvers (ENS, test fakes). Being a
    /// protocol requirement, a conformer's own implementation wins
    /// through `any ENSResolving` as well.
    func resolveName(_ name: String) async throws -> NameResolution {
        .content(try await resolveContent(name))
    }
}

/// Desktop's `content-name-resolver.js`: one entry point for every name
/// the browser resolves — `.tez` through Tezos Domains, everything else
/// through ENS (and the NameNFT systems it fronts). Conforms to
/// `ENSResolving`, so the scheme handlers, the favicon store and the
/// manifest fetcher take it unchanged.
@MainActor
final class ContentNameResolver: ENSResolving {
    let ens: ENSResolver
    let tezos: TezosDomainsResolver

    init(ens: ENSResolver, tezos: TezosDomainsResolver) {
        self.ens = ens
        self.tezos = tezos
    }

    /// Content only: a `.tez` name publishing an HTTP(S) website throws
    /// `TezosDomainsError.notContent`, since `ipfs://name.tez/…` cannot
    /// be served from it.
    func resolveContent(_ name: String) async throws -> ENSResolvedContent {
        switch try await resolveName(name) {
        case .content(let content): return content
        case .web(let url, _): throw TezosDomainsError.notContent(url)
        }
    }

    func resolveName(_ name: String) async throws -> NameResolution {
        guard TezosDomains.isName(name) else {
            return .content(try await ens.resolveContent(name))
        }
        let normalized = name.lowercased()
        switch await tezos.resolve(normalized) {
        case .ok(let record, let trust):
            switch record.kind {
            case .web:
                return .web(record.uri, trust: trust)
            case .ipfs, .ipns:
                // Served under the name so the page origin stays
                // `name.tez`; the scheme handler prepends `basePath`.
                let codec: ENSContentCodec = record.kind == .ipfs ? .ipfs : .ipns
                var components = URLComponents()
                components.scheme = codec.scheme
                components.host = normalized
                components.path = "/"
                guard let uri = components.url, let decoded = record.decoded else {
                    throw TezosDomainsError.unsupported(reason: "invalid website URI")
                }
                return .content(ENSResolvedContent(
                    name: normalized, uri: uri, contentRef: decoded, codec: codec, trust: trust, basePath: record.basePath
                ))
            }
        case .notFound(let reason):
            throw TezosDomainsError.notFound(reason: reason)
        case .unsupported(let reason):
            throw TezosDomainsError.unsupported(reason: reason)
        case .conflict(_, let groups, let trust):
            throw ENSResolutionError.conflict(groups: groups, trust: trust)
        case .error(let reason):
            throw TezosDomainsError.unavailable(reason: reason)
        }
    }
}
