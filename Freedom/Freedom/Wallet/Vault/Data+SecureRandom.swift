import Foundation
import Security

extension Data {
    /// System CSPRNG bytes. Returns nil on the vanishingly-rare
    /// `SecRandomCopyBytes` failure — callers choose whether that's a
    /// precondition or a thrown error in their domain.
    static func secureRandom(count: Int) -> Data? {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        return status == errSecSuccess ? data : nil
    }
}
