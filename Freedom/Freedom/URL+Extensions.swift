import Foundation

extension URL {
    /// User-presentable origin label. Host if available (the common case
    /// for http/https/bzz with authority), absolute string otherwise.
    var hostOrAbsolute: String {
        host ?? absoluteString
    }

    /// Lowercased ENS name if the URL's host is `.eth`-suffixed, nil
    /// otherwise. Used by the scheme handlers + favicon store +
    /// BrowserTab.reload to detect ENS-origin URLs and bind the name in
    /// one step. Lowercases internally because custom schemes
    /// (bzz/ipfs/ipns) preserve host case where standard schemes
    /// (http/https) normalize it.
    var ensName: String? {
        let lowered = host?.lowercased()
        return (lowered?.hasSuffix(".eth") ?? false) ? lowered : nil
    }
}
