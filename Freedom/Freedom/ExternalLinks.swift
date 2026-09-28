import Foundation

/// Links the browser cannot show itself — `mailto:`, `tel:`, `sms:`,
/// `magnet:`, app schemes — are handed to the system, but only with the
/// site's consent (desktop parity): a prompt per site with "remember",
/// through the site-permission store (`SitePermissionKind.externalApps`).
enum ExternalLinks {
    /// Schemes the browser renders or routes itself; anything else is an
    /// external app. `freedom` is the app's own link scheme (OpenLV).
    static let browserSchemes: Set<String> = [
        "http", "https", "bzz", "ipfs", "ipns", "ens", "rad", "web3", "freedom",
        "about", "blob", "data", "javascript", "file",
    ]

    static func isExternal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        return !browserSchemes.contains(scheme)
    }

    /// What the prompt names as the target.
    static func appName(for url: URL) -> String {
        switch url.scheme?.lowercased() ?? "" {
        case "mailto": "Mail"
        case "tel", "telprompt": "Phone"
        case "sms": "Messages"
        case "facetime", "facetime-audio": "FaceTime"
        case "maps": "Maps"
        case "itms", "itms-apps", "itms-appss": "the App Store"
        case "magnet": "a torrent app"
        case let scheme: "another app (\(scheme))"
        }
    }
}
