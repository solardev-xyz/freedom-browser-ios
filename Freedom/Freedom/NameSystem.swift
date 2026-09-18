import Foundation
import web3

/// Contract-backed Ethereum name systems on mainnet. Mirrors desktop's
/// `NAME_SYSTEMS` in `src/main/ens-resolver.js`: WNS ([z0r0z/wei-names])
/// and GNS ([lucadonnoh/gwei-names]) store resolver records directly on
/// NameNFT-style ERC-721 contracts, using ENS-style namehash token IDs
/// and ENS-compatible resolver function signatures — so the namehash,
/// calldata, and record decoding are shared with the ENS path; only the
/// call target differs (the registry contract instead of the Universal
/// Resolver).
enum NameSystem: String, Equatable, Sendable, CaseIterable {
    case ens
    case wns
    case gns

    var label: String {
        switch self {
        case .ens: "ENS"
        case .wns: "WNS"
        case .gns: "GNS"
        }
    }

    /// NameNFT registry contract on mainnet. Nil means the system
    /// resolves through the ENS Universal Resolver instead.
    var contractAddress: EthereumAddress? {
        switch self {
        case .ens: nil
        case .wns: "0x0000000000696760E15f265e828DB644A0c242EB"
        case .gns: "0x9D51D507BC7264d4fE8Ad1cf7Fe191933A0a81d6"
        }
    }

    /// Which system resolves `name`. `.box` intentionally maps to `.ens`
    /// — 3DNS `.box` names live in the ENS registry.
    static func forName(_ name: String) -> NameSystem {
        let lower = name.lowercased()
        if lower.hasSuffix(".wei") { return .wns }
        if lower.hasSuffix(".gwei") { return .gns }
        return .ens
    }

    /// Desktop's `isEnsHost` — true when `host` ends with a supported
    /// Ethereum-name suffix in any system (.eth/.box ENS, .wei WNS,
    /// .gwei GNS). Used for permission keying and wallet-recipient
    /// shape checks.
    static func isSupportedName(_ host: some StringProtocol) -> Bool {
        let lower = host.lowercased()
        return lower.hasSuffix(".eth") || lower.hasSuffix(".box")
            || lower.hasSuffix(".wei") || lower.hasSuffix(".gwei")
    }

    /// Suffixes the browser routes through name resolution (address bar,
    /// URL classification). `.box` is deliberately absent: it's also a
    /// real DNS TLD and iOS has always loaded it over https — changing
    /// that is a separate decision from adding .wei/.gwei, which have no
    /// DNS equivalent.
    static let navigableSuffixes: [String] = [".eth", ".wei", ".gwei"]

    /// ENSv2 candidate detection (desktop `isPotentialEnsName`, per the
    /// ENS readiness guide): any dot-separated string may be an ENS
    /// name — `.eth`, a DNS-imported name (`gregskril.com`), a
    /// subdomain, an emoji or IDN label. Shape check only; ENSIP-15
    /// normalization runs in the resolver. Used where the user *asked*
    /// for a name (wallet recipient, explicit `ens://` or content-scheme
    /// host), never to reroute a bare DNS name typed into the address
    /// bar away from HTTPS.
    static func isPotentialEnsName(_ value: some StringProtocol) -> Bool {
        guard value.contains(".") else { return false }
        for scalar in value.unicodeScalars {
            let v = scalar.value
            if v < 32 || v == 127 { return false }
            if " \t\n\r/:@?#%\\".unicodeScalars.contains(scalar) { return false }
        }
        return value.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty }
    }

    /// Hosts that mean "a public/loopback IPFS gateway URL pasted in
    /// gateway form" (`ipfs://ipfs.io/ipfs/<cid>`, Kubo dir-listing
    /// links as `ipfs://localhost:8080/ipfs/<cid>`), which the IPFS
    /// handler serves by its embedded reference. A gateway hostname is
    /// a well-formed DNS name, so name detection must decline these or
    /// the CID never loads (desktop `KNOWN_GATEWAY_HOSTS`).
    static func isKnownIpfsGatewayHost(_ host: some StringProtocol) -> Bool {
        let lower = host.lowercased()
        if knownIpfsGatewayHosts.contains(lower) { return true }
        return lower.hasSuffix(".localhost")
    }

    private static let knownIpfsGatewayHosts: Set<String> = [
        "localhost", "127.0.0.1", "0.0.0.0", "[::1]", "::1",
        "dweb.link", "ipfs.io", "gateway.ipfs.io",
        "cf-ipfs.com", "cloudflare-ipfs.com",
        "gateway.pinata.cloud", "nftstorage.link", "w3s.link",
        "4everland.io", "trustless-gateway.link",
    ]

    /// Systems the reverse-resolution fallback probes, in order. Desktop's
    /// `CONTRACT_BACKED_REVERSE_SYSTEMS`.
    static let contractBacked: [NameSystem] = [.wns, .gns]
}

/// ABI helpers for the NameNFT registry contracts. Forward lookups reuse
/// the ENS selectors (`contenthash(bytes32)` / `addr(bytes32)`) verbatim;
/// only `reverseResolve(address)` is NameNFT-specific.
enum NameNFTABI {
    /// `reverseResolve(address) returns (string)` — the NameNFT reverse
    /// record. Unlike the UR's `reverse()`, the contract does NOT
    /// forward-verify; callers must forward-resolve the claimed name
    /// before trusting it.
    static func encodeReverseResolve(address: EthereumAddress) throws -> Data {
        let encoder = ABIFunctionEncoder("reverseResolve")
        try encoder.encode(address)
        return try encoder.encoded()
    }

    /// Decode a single ABI `string` return.
    static func decodeStringResponse(_ hex: String) -> String? {
        guard let decoded = try? ABIDecoder.decodeData(hex, types: [String.self]),
              let name = try? decoded[0].decoded() as String else {
            return nil
        }
        return name
    }
}
