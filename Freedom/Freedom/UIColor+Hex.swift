import UIKit

extension UIColor {
    /// Hex-only CSS color parser. Accepts `#RGB`, `#RRGGBB`, `#RRGGBBAA`
    /// (and the same forms without the leading `#`). Returns `nil` for
    /// anything else — `rgb(...)`, `hsl(...)`, named colors are out of
    /// scope; the meta-tag use-case overwhelmingly ships hex.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        // Expand 3-char shorthand: "abc" → "aabbcc".
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((v >> 24) & 0xff) / 255
            g = CGFloat((v >> 16) & 0xff) / 255
            b = CGFloat((v >> 8)  & 0xff) / 255
            a = CGFloat( v        & 0xff) / 255
        } else {
            r = CGFloat((v >> 16) & 0xff) / 255
            g = CGFloat((v >> 8)  & 0xff) / 255
            b = CGFloat( v        & 0xff) / 255
            a = 1.0
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
