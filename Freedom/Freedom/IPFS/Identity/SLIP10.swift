import CryptoKit
import Foundation

/// Minimal SLIP-0010 Ed25519 derivation.
/// Spec: https://github.com/satoshilabs/slips/blob/master/slip-0010.md
///
/// Only hardened derivation is implemented because Ed25519 has no
/// public-key arithmetic — every path segment must be hardened. Paths
/// like `m/44'/73405'/0'/0'/0'` are parsed; non-hardened segments throw.
///
/// Mirrors the desktop derivation (`micro-key-producer/slip10.js`) so
/// the same BIP-39 seed produces the same Ed25519 keypair on both
/// platforms — which is the whole point of seed-derived identities.
enum SLIP10Ed25519 {
    enum Error: Swift.Error, Equatable {
        case invalidPath(String)
        case nonHardenedSegment(String)
    }

    /// Derived material at a SLIP-0010 path.
    struct DerivedKey {
        let key: Data        // 32 bytes — input seed for Curve25519 keygen
        let chainCode: Data  // 32 bytes — used for further child derivation
    }

    /// HMAC key for the master-node step. ASCII bytes of "ed25519 seed".
    private static let masterHMACKey = Data("ed25519 seed".utf8)

    /// Hardened derivation marker: child indices ≥ 2³¹ are hardened.
    private static let hardenedOffset: UInt32 = 0x80000000

    /// Derive at `path` (e.g. `m/44'/73405'/0'/0'/0'`) from a master seed
    /// (typically a 64-byte BIP-39 mnemonic seed).
    static func derive(seed: Data, path: String) throws -> DerivedKey {
        let indices = try parsePath(path)
        var current = master(seed: seed)
        for index in indices {
            current = childKey(parent: current, index: index)
        }
        return current
    }

    // MARK: - Implementation

    /// Master node: I = HMAC-SHA512("ed25519 seed", seed); split into (key, chainCode).
    private static func master(seed: Data) -> DerivedKey {
        let i = hmacSHA512(key: masterHMACKey, data: seed)
        return DerivedKey(key: i.prefix(32), chainCode: i.suffix(32))
    }

    /// Hardened child: data = 0x00 || parent.key (32) || ser32(index) (4),
    /// I = HMAC-SHA512(parent.chainCode, data); split into (key, chainCode).
    private static func childKey(parent: DerivedKey, index: UInt32) -> DerivedKey {
        var data = Data(capacity: 1 + 32 + 4)
        data.append(0x00)
        data.append(parent.key)
        data.append(UInt8((index >> 24) & 0xff))
        data.append(UInt8((index >> 16) & 0xff))
        data.append(UInt8((index >> 8)  & 0xff))
        data.append(UInt8( index        & 0xff))
        let i = hmacSHA512(key: parent.chainCode, data: data)
        return DerivedKey(key: i.prefix(32), chainCode: i.suffix(32))
    }

    private static func hmacSHA512(key: Data, data: Data) -> Data {
        let mac = HMAC<SHA512>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return mac.withUnsafeBytes { Data($0) }
    }

    /// Parse `m/44'/73405'/0'/0'/0'` into hardened-bit-set UInt32 indices.
    /// All segments must end with `'` (hardened); non-hardened paths
    /// aren't valid for Ed25519 SLIP-0010.
    static func parsePath(_ path: String) throws -> [UInt32] {
        if path == "m" { return [] }
        guard path.hasPrefix("m/") else { throw Error.invalidPath(path) }
        let body = String(path.dropFirst(2))
        guard !body.isEmpty else { throw Error.invalidPath(path) }
        return try body.split(separator: "/").map { segment in
            let s = String(segment)
            guard s.hasSuffix("'") else { throw Error.nonHardenedSegment(s) }
            let stripped = String(s.dropLast())
            guard let n = UInt32(stripped), n < hardenedOffset else {
                throw Error.invalidPath(s)
            }
            return n | hardenedOffset
        }
    }
}
