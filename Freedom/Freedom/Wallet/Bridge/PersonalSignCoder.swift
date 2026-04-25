import Foundation
import web3

/// Decodes `personal_sign` params with two ambiguities handled for parity
/// with other wallets:
/// - **Param order**: MetaMask's canonical form is `[message, address]`
///   but some dapps send `[address, message]`. Disambiguate by shape
///   (address = `0x` + 40 hex); the non-address param is the message.
/// - **Message encoding**: a `0x`-prefixed even-length hex string is raw
///   bytes; anything else is UTF-8.
enum PersonalSignCoder {
    struct Decoded {
        let message: Data
        let declaredAddress: String
        let preview: Preview
    }

    enum Preview: Equatable {
        case utf8(String)
        case hex(String)
    }

    enum Error: Swift.Error {
        case badParams
    }

    static func decode(params: [Any]) throws -> Decoded {
        guard params.count == 2,
              let p0 = params[0] as? String,
              let p1 = params[1] as? String else {
            throw Error.badParams
        }

        let p0IsAddress = Hex.isAddressShape(p0)
        let p1IsAddress = Hex.isAddressShape(p1)
        let address: String
        let messageString: String
        switch (p0IsAddress, p1IsAddress) {
        case (true, false):
            address = p0
            messageString = p1
        case (false, true):
            address = p1
            messageString = p0
        case (true, true):
            // Both address-like — a 40-hex message is ambiguous. Fall back
            // to MetaMask convention: [message, address].
            messageString = p0
            address = p1
        case (false, false):
            throw Error.badParams
        }

        let (bytes, preview) = decodeMessage(messageString)
        return Decoded(message: bytes, declaredAddress: address, preview: preview)
    }

    private static func decodeMessage(_ s: String) -> (Data, Preview) {
        if (s.hasPrefix("0x") || s.hasPrefix("0X")),
           let bytes = s.web3.hexData,
           s.count.isMultiple(of: 2) {
            return (bytes, isPrintableUTF8(bytes)
                ? .utf8(String(decoding: bytes, as: UTF8.self))
                : .hex(s))
        }
        return (Data(s.utf8), .utf8(s))
    }

    /// Shown-as-text vs shown-as-hex decision. Printable means: decodes
    /// as UTF-8 AND contains no control characters other than tab / LF / CR.
    private static func isPrintableUTF8(_ data: Data) -> Bool {
        guard let s = String(data: data, encoding: .utf8) else { return false }
        return s.rangeOfCharacter(from: nonPrintableControls) == nil
    }

    private static let nonPrintableControls: CharacterSet = CharacterSet.controlCharacters
        .subtracting(CharacterSet(charactersIn: "\n\t\r"))
}
