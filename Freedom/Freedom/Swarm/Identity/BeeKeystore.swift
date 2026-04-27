import CommonCrypto
import CryptoSwift
import Foundation
import web3

/// V3 Ethereum keystore JSON encoder/decoder, locked to the parameters Bee
/// mandates: scrypt KDF (`bee/v2/pkg/keystore/file/key.go:30` — Bee rejects
/// every other KDF), AES-128-CTR cipher, keccak256 MAC over `derivedKey[16..32]
/// ++ ciphertext`. We don't implement any primitive ourselves — `CryptoSwift`
/// for scrypt, `CommonCrypto` for AES, `web3.swift` for keccak. This file is
/// just plumbing.
enum BeeKeystore {
    enum Error: Swift.Error, Equatable {
        case invalidPrivateKey
        case randomFailure
        case scryptFailure
        case cipherFailure
        case malformedKeystore(String)
        case unsupportedKDF(String)
        case unsupportedCipher(String)
        case wrongPassword
    }

    // V3 / Bee parameter set. Constants centralised here so the encoder and
    // decoder agree without a free-form spec to drift against.
    static let scryptN = 32768
    static let scryptR = 8
    static let scryptP = 1
    static let dkLen = 32
    static let saltBytes = 32
    static let ivBytes = 16
    private static let kdfName = "scrypt"
    private static let cipherName = "aes-128-ctr"

    /// Encrypt a 32-byte secp256k1 private key into a Bee-compatible V3
    /// keystore JSON document. `address` is the unprefixed-hex Ethereum
    /// address of the key — passed in (not re-derived) so the caller can
    /// reuse a derivation it already had to do via `HDKey.ethereumAddress`.
    /// `salt`, `iv`, and `id` default to fresh CSPRNG values; tests pass
    /// deterministic values to check byte-stable output for known inputs.
    static func encrypt(
        privateKey: Data,
        password: String,
        address: String,
        salt: Data? = nil,
        iv: Data? = nil,
        id: UUID = UUID()
    ) throws -> Data {
        guard privateKey.count == 32 else { throw Error.invalidPrivateKey }
        let saltData = try salt ?? secureRandom(count: saltBytes)
        let ivData = try iv ?? secureRandom(count: ivBytes)
        guard saltData.count == saltBytes, ivData.count == ivBytes else {
            throw Error.malformedKeystore("salt/iv length mismatch")
        }

        let derivedKey = try runScrypt(password: password, salt: saltData,
                                       n: scryptN, r: scryptR, p: scryptP, dkLen: dkLen)
        let encKey = derivedKey.prefix(16)
        let macKey = derivedKey.suffix(16)

        let ciphertext = try aesCTR(key: Data(encKey), iv: ivData, input: privateKey)
        let mac = (Data(macKey) + ciphertext).web3.keccak256

        let payload = KeystoreFile(
            address: address,
            crypto: KeystoreCrypto(
                cipher: cipherName,
                ciphertext: ciphertext.web3.hexString.web3.noHexPrefix,
                cipherparams: CipherParams(iv: ivData.web3.hexString.web3.noHexPrefix),
                kdf: kdfName,
                kdfparams: KDFParams(
                    n: scryptN, r: scryptR, p: scryptP,
                    dklen: dkLen,
                    salt: saltData.web3.hexString.web3.noHexPrefix
                ),
                mac: mac.web3.hexString.web3.noHexPrefix
            ),
            id: id.uuidString.lowercased(),
            version: 3
        )

        let encoder = JSONEncoder()
        // Compact output — the file Bee actually opens has no whitespace either.
        encoder.outputFormatting = []
        return try encoder.encode(payload)
    }

    /// Decrypt a V3 keystore JSON. Used by tests to round-trip our encoder
    /// output. Available in production for any future "verify keystore is
    /// readable before restart" sanity check.
    static func decrypt(_ json: Data, password: String) throws -> Data {
        let payload = try JSONDecoder().decode(KeystoreFile.self, from: json)
        guard payload.version == 3 else {
            throw Error.malformedKeystore("unsupported version \(payload.version)")
        }
        guard payload.crypto.kdf == kdfName else {
            throw Error.unsupportedKDF(payload.crypto.kdf)
        }
        guard payload.crypto.cipher == cipherName else {
            throw Error.unsupportedCipher(payload.crypto.cipher)
        }
        guard let salt = Data(hex: payload.crypto.kdfparams.salt),
              let iv = Data(hex: payload.crypto.cipherparams.iv),
              let ciphertext = Data(hex: payload.crypto.ciphertext),
              let expectedMAC = Data(hex: payload.crypto.mac) else {
            throw Error.malformedKeystore("invalid hex in keystore body")
        }

        let derivedKey = try runScrypt(
            password: password, salt: salt,
            n: payload.crypto.kdfparams.n,
            r: payload.crypto.kdfparams.r,
            p: payload.crypto.kdfparams.p,
            dkLen: payload.crypto.kdfparams.dklen
        )
        let macKey = derivedKey.suffix(16)
        let actualMAC = (Data(macKey) + ciphertext).web3.keccak256
        guard actualMAC == expectedMAC else { throw Error.wrongPassword }

        let encKey = derivedKey.prefix(16)
        return try aesCTR(key: Data(encKey), iv: iv, input: ciphertext)
    }

    // MARK: - Internals

    private static func secureRandom(count: Int) throws -> Data {
        guard let data = Data.secureRandom(count: count) else { throw Error.randomFailure }
        return data
    }

    private static func runScrypt(
        password: String, salt: Data,
        n: Int, r: Int, p: Int, dkLen: Int
    ) throws -> Data {
        do {
            let kdf = try Scrypt(
                password: Array(password.utf8),
                salt: Array(salt),
                dkLen: dkLen, N: n, r: r, p: p
            )
            return Data(try kdf.calculate())
        } catch {
            throw Error.scryptFailure
        }
    }

    /// AES-128-CTR is symmetric — encrypt and decrypt run the same XOR
    /// keystream, so callers route both directions through this single helper.
    /// `kCCModeOptionCTR_BE` matches the big-endian counter every other V3
    /// keystore implementation (ethers, go-ethereum, Bee) uses.
    private static func aesCTR(key: Data, iv: Data, input: Data) throws -> Data {
        var cryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivPtr.baseAddress, keyPtr.baseAddress, key.count,
                    nil, 0, 0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }
        guard createStatus == kCCSuccess, let cryptor else { throw Error.cipherFailure }
        defer { CCCryptorRelease(cryptor) }

        var output = Data(count: input.count + kCCBlockSizeAES128)
        // Read the buffer size before entering `withUnsafeMutableBytes` —
        // Swift's exclusivity rules forbid touching `output` while the
        // closure holds a mutable pointer into it.
        let outputCapacity = output.count
        var moved = 0
        let updateStatus = output.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                CCCryptorUpdate(
                    cryptor,
                    inPtr.baseAddress, input.count,
                    outPtr.baseAddress, outputCapacity,
                    &moved
                )
            }
        }
        guard updateStatus == kCCSuccess else { throw Error.cipherFailure }
        return output.prefix(moved)
    }

}

// MARK: - V3 keystore Codable shape
//
// Field order matches Bee's Go struct (`bee/v2/pkg/keystore/file/key.go:40-66`).
// JSON parsing is order-insensitive, but mirroring the source-of-truth shape
// keeps byte-diff comparisons sane and avoids surprises if a future decoder
// is strict about it.

private struct KeystoreFile: Codable {
    let address: String
    let crypto: KeystoreCrypto
    let id: String
    let version: Int
}

private struct KeystoreCrypto: Codable {
    let cipher: String
    let ciphertext: String
    let cipherparams: CipherParams
    let kdf: String
    let kdfparams: KDFParams
    let mac: String
}

private struct CipherParams: Codable {
    let iv: String
}

private struct KDFParams: Codable {
    let n: Int
    let r: Int
    let p: Int
    let dklen: Int
    let salt: String
}
