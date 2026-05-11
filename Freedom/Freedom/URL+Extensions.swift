import Foundation

extension URL {
    /// User-presentable origin label. Host if available (the common case
    /// for http/https/bzz with authority), absolute string otherwise.
    var hostOrAbsolute: String {
        host ?? absoluteString
    }

    /// True when the URL's host is an ENS name (`.eth` suffix). Used by
    /// the scheme handlers to decide whether to run ENS resolution
    /// before forming the upstream fetch, and by BrowserTab.reload to
    /// re-trigger ENS resolution on pull-to-refresh. Lowercases before
    /// the suffix check because custom schemes (bzz/ipfs/ipns) preserve
    /// host case where standard schemes (http/https) normalize it.
    var isENSNamedHost: Bool {
        host?.lowercased().hasSuffix(".eth") ?? false
    }
}
