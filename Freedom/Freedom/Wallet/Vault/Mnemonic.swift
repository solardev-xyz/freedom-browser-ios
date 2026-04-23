import CommonCrypto
import CryptoKit
import Foundation

struct Mnemonic: Equatable {
    enum Error: Swift.Error, Equatable {
        case invalidEntropyLength
        case invalidWordCount
        case unknownWord(String)
        case invalidChecksum
    }

    enum Strength: Int {
        case bits128 = 128
        case bits160 = 160
        case bits192 = 192
        case bits224 = 224
        case bits256 = 256

        var wordCount: Int { (rawValue + rawValue / 32) / 11 }

        init?(wordCount: Int) {
            switch wordCount {
            case 12: self = .bits128
            case 15: self = .bits160
            case 18: self = .bits192
            case 21: self = .bits224
            case 24: self = .bits256
            default: return nil
            }
        }
    }

    let words: [String]

    init(strength: Strength = .bits256) {
        guard let entropy = Data.secureRandom(count: strength.rawValue / 8) else {
            preconditionFailure("SecRandomCopyBytes failed — no seed source")
        }
        self = try! Mnemonic(entropy: entropy)
    }

    init(entropy: Data) throws {
        guard Strength(rawValue: entropy.count * 8) != nil else {
            throw Error.invalidEntropyLength
        }
        let checksumBitCount = entropy.count * 8 / 32
        let checksum = Data(SHA256.hash(data: entropy))
        let totalBits = entropy.count * 8 + checksumBitCount
        var result: [String] = []
        result.reserveCapacity(totalBits / 11)
        for i in 0..<(totalBits / 11) {
            var idx: UInt32 = 0
            for bit in 0..<11 {
                let absolute = i * 11 + bit
                let byte: UInt8
                if absolute < entropy.count * 8 {
                    byte = entropy[absolute / 8]
                } else {
                    byte = checksum[(absolute - entropy.count * 8) / 8]
                }
                let bitVal = UInt32((byte >> UInt8(7 - absolute % 8)) & 1)
                idx = (idx << 1) | bitVal
            }
            result.append(BIP39English.words[Int(idx)])
        }
        self.words = result
    }

    init(phrase: String) throws {
        let parsed = phrase
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard Strength(wordCount: parsed.count) != nil else {
            throw Error.invalidWordCount
        }
        let index = Mnemonic.wordIndex
        var bits: [UInt8] = []
        bits.reserveCapacity(parsed.count * 11)
        for word in parsed {
            guard let i = index[word] else { throw Error.unknownWord(word) }
            for b in stride(from: 10, through: 0, by: -1) {
                bits.append(UInt8((i >> b) & 1))
            }
        }
        let entropyBitCount = parsed.count * 11 * 32 / 33
        let checksumBitCount = entropyBitCount / 32
        var entropy = Data(count: entropyBitCount / 8)
        for (i, bit) in bits.prefix(entropyBitCount).enumerated() {
            entropy[i / 8] |= UInt8(bit) << UInt8(7 - i % 8)
        }
        let expected = SHA256.hash(data: entropy)
        var expectedBits: [UInt8] = []
        for byte in expected {
            for b in stride(from: 7, through: 0, by: -1) {
                expectedBits.append(UInt8((byte >> b) & 1))
                if expectedBits.count == checksumBitCount { break }
            }
            if expectedBits.count == checksumBitCount { break }
        }
        guard Array(bits.suffix(checksumBitCount)) == expectedBits else {
            throw Error.invalidChecksum
        }
        self.words = parsed
    }

    /// BIP-39 seed: PBKDF2-SHA512 of the NFKD mnemonic with salt
    /// `"mnemonic" + NFKD(passphrase)`, 2048 rounds, 64-byte output.
    func seed(passphrase: String = "") -> Data {
        let mnemonicStr = words
            .joined(separator: " ")
            .decomposedStringWithCompatibilityMapping
        let saltStr = ("mnemonic" + passphrase)
            .decomposedStringWithCompatibilityMapping
        let passwordUTF8Length = mnemonicStr.utf8.count
        let saltBytes = Array(saltStr.utf8)
        var derived = [UInt8](repeating: 0, count: 64)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            mnemonicStr, passwordUTF8Length,
            saltBytes, saltBytes.count,
            CCPBKDFAlgorithm(kCCPRFHmacAlgSHA512),
            2048,
            &derived, derived.count
        )
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return Data(derived)
    }

    private static let wordIndex: [String: Int] = Dictionary(
        uniqueKeysWithValues: BIP39English.words.enumerated().map { ($1, $0) }
    )
}
