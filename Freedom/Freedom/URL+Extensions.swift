import Foundation

extension URL {
    /// User-presentable origin label. Host if available (the common case
    /// for http/https/bzz with authority), absolute string otherwise.
    var hostOrAbsolute: String {
        host ?? absoluteString
    }
}
