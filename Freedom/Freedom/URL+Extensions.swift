import Foundation

extension URL {
    /// User-presentable origin label. Host if available (the common case
    /// for http/https/bzz with authority), absolute string otherwise.
    var hostOrAbsolute: String {
        host ?? absoluteString
    }

    /// Lowercased Ethereum name if the URL's host carries a resolvable
    /// name suffix (`.eth` ENS, `.wei` WNS, `.gwei` GNS), nil otherwise.
    /// Used by the scheme handlers + favicon store + BrowserTab.reload to
    /// detect name-origin URLs and bind the name in one step. Lowercases
    /// internally because custom schemes (bzz/ipfs/ipns) preserve host
    /// case where standard schemes (http/https) normalize it.
    var ensName: String? {
        guard let lowered = host?.lowercased() else { return nil }
        return NameSystem.navigableSuffixes.contains(where: lowered.hasSuffix) ? lowered : nil
    }
}
