import Foundation
import WebKit

/// Friendly error pages for ordinary web loads that WebKit gives up on
/// (desktop "Friendly Error Pages": the message names the cause, the
/// original URL stays in the address bar, reload retries it). The dweb
/// scheme handlers serve their own pages (`SchemeHandlerErrorPage`);
/// this covers http(s) and any handler that fails outright.
enum WebErrorPage {
    enum Kind: Equatable {
        case offline
        case hostNotFound
        case cannotConnect
        case timedOut
        /// TLS failed: the certificate is untrusted, expired, not yet
        /// valid, for another host, or the handshake broke. Never
        /// bypassed — the page is not loaded.
        case certificate(reason: String)
        /// The server asked for a client certificate (not supported yet).
        case clientCertificate
        /// App Transport Security refused a cleartext or weak connection.
        case insecureBlocked
        case generic(message: String)
    }

    /// What to show for a navigation failure, or nil when the failure
    /// is not a failure: WebKit cancels (a new navigation, stop, a
    /// download or a scheme handler taking over).
    static func kind(for error: Error) -> Kind? {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: nsError.code) {
            case .cancelled: return nil
            case .notConnectedToInternet: return .offline
            case .cannotFindHost, .dnsLookupFailed: return .hostNotFound
            case .cannotConnectToHost, .networkConnectionLost: return .cannotConnect
            case .timedOut: return .timedOut
            case .serverCertificateUntrusted: return .certificate(reason: "the certificate isn't trusted")
            case .serverCertificateHasBadDate: return .certificate(reason: "the certificate has expired")
            case .serverCertificateNotYetValid: return .certificate(reason: "the certificate isn't valid yet")
            case .serverCertificateHasUnknownRoot: return .certificate(reason: "the certificate's issuer isn't known")
            case .secureConnectionFailed: return .certificate(reason: "the secure connection couldn't be made")
            case .clientCertificateRequired, .clientCertificateRejected: return .clientCertificate
            case .appTransportSecurityRequiresSecureConnection: return .insecureBlocked
            default: return .generic(message: nsError.localizedDescription)
            }
        }
        if nsError.domain == "WebKitErrorDomain" {
            // 102 frame load interrupted (a download, a handler took over),
            // 204 plug-in handled the load: nothing to show.
            if nsError.code == 102 || nsError.code == 204 { return nil }
        }
        return .generic(message: nsError.localizedDescription)
    }

    /// The URL that failed, as WebKit reports it on the error.
    static func failedURL(_ error: Error) -> URL? {
        let info = (error as NSError).userInfo
        if let url = info[NSURLErrorFailingURLErrorKey] as? URL { return url }
        if let raw = info[NSURLErrorFailingURLStringErrorKey] as? String { return URL(string: raw) }
        return nil
    }

    static func heading(_ kind: Kind) -> String {
        switch kind {
        case .offline: "You're offline"
        case .hostNotFound: "Site not found"
        case .cannotConnect: "Can't connect"
        case .timedOut: "The site took too long"
        case .certificate: "This connection isn't private"
        case .clientCertificate: "This site needs a certificate"
        case .insecureBlocked: "Insecure connection blocked"
        case .generic: "Can't open this page"
        }
    }

    static func message(_ kind: Kind, host: String) -> String {
        switch kind {
        case .offline: "Freedom can't reach the network. Check Wi-Fi or mobile data and try again."
        case .hostNotFound: "The server for \(host) couldn't be found. Check the address for typos."
        case .cannotConnect: "\(host) didn't answer, or the connection dropped. The site may be down."
        case .timedOut: "\(host) took too long to respond. Try again in a moment."
        case .certificate(let reason): "Freedom couldn't verify \(host): \(reason). The page was not loaded, and Freedom never bypasses certificate errors."
        case .clientCertificate: "\(host) asked for a client certificate. Freedom doesn't support client certificates yet."
        case .insecureBlocked: "\(host) uses a cleartext or weak connection that iOS blocks."
        case .generic(let message): message
        }
    }

    static func render(_ kind: Kind, url: URL) -> String {
        let host = url.host(percentEncoded: false) ?? url.absoluteString
        let retry = SchemeHandlerErrorPage.escape(url.absoluteString)
        return SchemeHandlerErrorPage.page(
            title: SchemeHandlerErrorPage.escape(heading(kind)),
            heading: SchemeHandlerErrorPage.escape(heading(kind)),
            body: """
            <p>\(SchemeHandlerErrorPage.escape(message(kind, host: host)))</p>
            <p class="detail"><code>\(retry)</code></p>
            <p><a href="\(retry)">Try again</a></p>
            """
        )
    }
}
