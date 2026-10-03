import Foundation

/// A URL handed to the app from outside — another app, a share sheet
/// action, the default-browser role (desktop "open links from other
/// apps"). `freedom://…#openlv://…` is the phone-signing pairing link;
/// a page the browser can show opens in a new tab; an EIP-681
/// `ethereum:` link opens the Send form; the rest is not ours.
enum IncomingLink: Equatable {
    case openLV(uri: String)
    case page(BrowserURL)
    case payment(URL)
    case unsupported

    /// Schemes a page can arrive on. `BrowserURL.parse`'s hostname
    /// heuristics are for typed input, so anything else is refused
    /// before it can be mistaken for a host (`mailto:a@b` is not
    /// `https://mailto:a@b`).
    static let pageSchemes: Set<String> = ["http", "https", "bzz", "ipfs", "ipns", "ens", "tez", "rad", "web3"]

    static func classify(_ url: URL) -> IncomingLink {
        if let uri = OpenLVWalletSession.extractOpenLVURI(from: url.absoluteString) {
            return .openLV(uri: uri)
        }
        guard let scheme = url.scheme?.lowercased() else { return .unsupported }
        if scheme == EthereumURI.scheme { return .payment(url) }
        guard pageSchemes.contains(scheme) else { return .unsupported }
        if let browserURL = BrowserURL.classify(url) ?? BrowserURL.parse(url.absoluteString) {
            return .page(browserURL)
        }
        return .unsupported
    }
}
