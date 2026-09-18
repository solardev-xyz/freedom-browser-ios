import Foundation
import web3

/// A contract-hosted application (draft ERC-8244): an app whose whole
/// document is the return value of the contract's `html()` view on an
/// EVM chain. Desktop parity (`src/main/onchain/onchain-app-protocol.js`
/// and `src/shared/origin-utils.js`).
///
/// Two URL shapes carry the same app:
///
///   web3://<contract>[:<chainId>]/…        friendly — address bar, history,
///                                          bookmarks, approval sheets
///   web3://<contract>.eip155-<chainId>/…   canonical — what WebKit loads
///
/// The canonical hostname gives every contract-and-chain pair its own
/// web origin (storage, cookies) without a port in the host, which the
/// URL parser would treat as a real port and WebKit's port blocklist
/// would refuse for small chain IDs. Freedom's own surfaces reverse-map
/// it to the friendly form.
struct OnchainAppRef: Hashable, Sendable {
    /// EIP-55 checksummed contract address.
    let address: String
    let chainID: Int

    static let defaultChainID = Chain.mainnetID
    static let scheme = "web3"

    /// `bytes4(keccak256("html()"))`.
    static let htmlSelector = "0x33c34ac3"
    /// Decoded-document cap (desktop: 8 MiB).
    static let maxHTMLBytes = 8 * 1024 * 1024
    /// Wall-clock budget for the `html()` read across every tier.
    static let requestTimeout: TimeInterval = 30

    init?(address: String, chainID: Int) {
        guard Hex.isAddressShape(address), chainID >= 1 else { return nil }
        self.address = EthereumAddress(address).toChecksumAddress()
        self.chainID = chainID
    }

    var lowercasedAddress: String { address.lowercased() }

    /// Parse either URL shape. Returns the app plus the percent-encoded
    /// `path?query#fragment` tail (`""` for root), the same tail shape
    /// `BrowserURL.ens` carries.
    static func parse(_ url: URL) -> (app: OnchainAppRef, tail: String)? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let app: OnchainAppRef?
        if let range = host.range(of: ".eip155-") {
            guard components.port == nil,
                  let chainID = Int(host[range.upperBound...]) else { return nil }
            app = OnchainAppRef(address: String(host[..<range.lowerBound]), chainID: chainID)
        } else {
            app = OnchainAppRef(address: host, chainID: components.port ?? defaultChainID)
        }
        guard let app else { return nil }
        var tail = components.percentEncodedPath
        if tail == "/" { tail = "" }
        if let query = components.percentEncodedQuery, !query.isEmpty { tail += "?\(query)" }
        if let fragment = components.percentEncodedFragment, !fragment.isEmpty { tail += "#\(fragment)" }
        return (app, tail)
    }

    /// The friendly form, always with at least a root path.
    func displayURL(tail: String = "") -> URL {
        let chain = chainID == Self.defaultChainID ? "" : ":\(chainID)"
        return URL(string: "\(Self.scheme)://\(address)\(chain)\(Self.normalizedTail(tail))")!
    }

    /// The canonical, chain-scoped origin WebKit loads.
    func canonicalURL(tail: String = "") -> URL {
        URL(string: "\(Self.scheme)://\(lowercasedAddress).eip155-\(chainID)\(Self.normalizedTail(tail))")!
    }

    /// Desktop's `getPermissionKey`: `web3://<addr>` on mainnet,
    /// `web3://<addr>:<chainId>` elsewhere, lowercase address, no path.
    /// A different chain is a different app and must never inherit
    /// wallet grants.
    var permissionKey: String {
        let chain = chainID == Self.defaultChainID ? "" : ":\(chainID)"
        return "\(Self.scheme)://\(lowercasedAddress)\(chain)"
    }

    /// Short label for chrome: `0x0000…56c6` plus the chain when not mainnet.
    var shortLabel: String {
        let short = address.prefix(6) + "…" + address.suffix(4)
        return chainID == Self.defaultChainID ? String(short) : "\(short):\(chainID)"
    }

    private static func normalizedTail(_ tail: String) -> String {
        if tail.isEmpty { return "/" }
        if tail.hasPrefix("/") || tail.hasPrefix("?") || tail.hasPrefix("#") {
            return tail.hasPrefix("/") ? tail : "/" + tail
        }
        return "/" + tail
    }
}

enum OnchainAppError: Error, Equatable {
    /// The chain isn't registered in the wallet's chain list.
    case unknownChain(chainID: Int)
    /// Every source failed to answer the `html()` read.
    case unreachable
    /// The contract reverted or returned malformed data.
    case notAnApp(detail: String)
    case tooLarge
    case timedOut
}

extension OnchainAppRef {
    /// ABI-decode the `html() returns (string)` result. The encoded size
    /// is checked before decoding so an oversized answer never gets
    /// materialized: ABI adds an offset word, a length word and up to 31
    /// bytes of padding.
    static func decodeHTML(_ resultHex: String) throws -> String {
        let stripped = resultHex.lowercased().hasPrefix("0x") ? String(resultHex.dropFirst(2)) : resultHex
        guard !stripped.isEmpty, stripped.count % 2 == 0,
              stripped.allSatisfy(\.isHexDigit) else {
            throw OnchainAppError.notAnApp(detail: "html() returned malformed ABI data")
        }
        if stripped.count / 2 > maxHTMLBytes + 95 { throw OnchainAppError.tooLarge }
        let html: String
        do {
            let decoded = try ABIDecoder.decodeData("0x" + stripped, types: [String.self])
            html = try decoded[0].decoded()
        } catch {
            throw OnchainAppError.notAnApp(detail: "html() returned malformed ABI data")
        }
        if html.utf8.count > maxHTMLBytes { throw OnchainAppError.tooLarge }
        return html
    }

    /// `keccak256(utf8(html))`, `0x`-prefixed — the identity the user
    /// approves on the interstitial and the shield shows.
    static func htmlHash(_ html: String) -> String {
        Data(html.utf8).web3.keccak256.web3.hexString
    }
}

/// What the shield and the interstitial say about a loaded app. `trust`
/// reuses the ENS trust vocabulary (level + method + hosts) so the
/// address-bar shield renders it unchanged.
struct OnchainAppProvenance: Equatable, Sendable {
    let app: OnchainAppRef
    let networkName: String
    let htmlHash: String
    let trust: ENSTrust

    /// Which source served the document, for the interstitial.
    var source: String { trust.agreed.first ?? trust.queried.first ?? "unknown" }

    /// Endpoints answered but disagreed and no verified tier settled it:
    /// the bytes cannot be trusted, and "continue once" is not offered
    /// (desktop PR #232's hard block).
    var hasConflict: Bool {
        !trust.dissented.isEmpty && trust.level != .verified
    }

    /// Verified (Myotis / Colibri / quorum) documents and the user's own
    /// endpoint load directly.
    var isTrusted: Bool {
        guard !hasConflict else { return false }
        switch trust.level {
        case .verified, .userConfigured: return true
        case .unverified, .conflict: return false
        }
    }
}

/// A fetched document plus its provenance — what the tab stages for the
/// scheme handler and what the interstitial holds while the user decides.
struct OnchainAppDocument: Equatable, Sendable {
    let html: String
    let provenance: OnchainAppProvenance

    var app: OnchainAppRef { provenance.app }
}
