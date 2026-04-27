import CryptoKit
import Foundation
import secp256k1
import web3

struct HDKey: Equatable {
    enum Error: Swift.Error, Equatable {
        case invalidPath(String)
    }

    let privateKey: Data
    let chainCode: Data

    init(seed: Data) throws {
        let mac = HMAC<SHA512>.authenticationCode(
            for: seed,
            using: SymmetricKey(data: Data("Bitcoin seed".utf8))
        )
        let bytes = Data(mac)
        let pk = Data(bytes.prefix(32))
        let cc = Data(bytes.suffix(32))
        // Throws on the astronomically-unlikely zero / out-of-range scalar
        // (≈ 2⁻¹²⁸). BIP-32 leaves the "try next index" recovery to callers
        // of `child(at:)`; the master seed path has no next index, so we
        // propagate rather than pretend.
        _ = try secp256k1.Signing.PrivateKey(dataRepresentation: pk)
        self.privateKey = pk
        self.chainCode = cc
    }

    private init(privateKey: Data, chainCode: Data) {
        self.privateKey = privateKey
        self.chainCode = chainCode
    }

    /// Hardened indices (>= 2³¹) feed the parent *private* key into the HMAC;
    /// non-hardened feed the parent compressed *public* key. Mixing the two
    /// is the whole point of BIP-32.
    func child(at index: UInt32) throws -> HDKey {
        var msg = Data()
        let hardened = index >= 0x8000_0000
        if hardened {
            msg.append(0x00)
            msg.append(privateKey)
        } else {
            let parent = try secp256k1.Signing.PrivateKey(dataRepresentation: privateKey)
            msg.append(parent.publicKey.dataRepresentation)
        }
        var idxBE = index.bigEndian
        withUnsafeBytes(of: &idxBE) { msg.append(contentsOf: $0) }

        let mac = HMAC<SHA512>.authenticationCode(
            for: msg,
            using: SymmetricKey(data: chainCode)
        )
        let h = Data(mac)
        let il = Array(h.prefix(32))
        let ir = Data(h.suffix(32))
        let parent = try secp256k1.Signing.PrivateKey(dataRepresentation: privateKey)
        let tweaked = try parent.add(il)
        return HDKey(privateKey: tweaked.dataRepresentation, chainCode: ir)
    }

    func derive(_ path: Path) throws -> HDKey {
        var key = self
        for index in path.indices {
            key = try key.child(at: index)
        }
        return key
    }

    /// EIP-55 mixed-case checksumming is deliberately *not* applied here —
    /// callers that want it apply it at the UI layer.
    var ethereumAddress: String {
        get throws {
            let uncompressed = try secp256k1.Signing.PrivateKey(
                dataRepresentation: privateKey,
                format: .uncompressed
            )
            let pub = uncompressed.publicKey.dataRepresentation
            let hash = Data(pub.dropFirst()).web3.keccak256
            return Data(hash.suffix(20)).web3.hexString
        }
    }
}

extension HDKey {
    /// Typed BIP-44 path. Callers use the factory methods; free-form strings
    /// parse through `init(rawPath:)`, which is the only place the grammar
    /// lives. Keeps `derive(_:)` from being stringly-typed.
    struct Path: Equatable {
        let rawPath: String
        let indices: [UInt32]

        init(rawPath: String) throws {
            let components = rawPath.split(separator: "/")
            guard components.first == "m" else {
                throw HDKey.Error.invalidPath(rawPath)
            }
            var result: [UInt32] = []
            for c in components.dropFirst() {
                let hardened = c.hasSuffix("'")
                let raw = hardened ? String(c.dropLast()) : String(c)
                guard let n = UInt32(raw), n < 0x8000_0000 else {
                    throw HDKey.Error.invalidPath(rawPath)
                }
                result.append(hardened ? n | 0x8000_0000 : n)
            }
            self.rawPath = rawPath
            self.indices = result
        }

        /// Main user wallet (also account 0).
        static let mainUser = try! Path(rawPath: "m/44'/60'/0'/0/0")
        /// Bee-node wallet. The Bee node's identity (overlay address, on-chain
        /// xDAI/xBZZ wallet) is derived from this slot; matches desktop's
        /// `derivation.js` `BEE_WALLET` so the same mnemonic produces the same
        /// Swarm overlay address on iOS and desktop.
        static let beeWallet = try! Path(rawPath: "m/44'/60'/0'/0/1")
        /// Additional user wallets. `userAccount(0)` is an alias for `mainUser`.
        static func userAccount(_ i: Int) -> Path {
            // Hardened BIP-32 components are [0, 2³¹); checking explicitly
            // here keeps the `try!` on the next line provably safe rather
            // than letting bad migrated / UI-driven state reach the parser.
            precondition(
                i >= 0 && i < 0x8000_0000,
                "account index \(i) out of range [0, 2³¹)"
            )
            return try! Path(rawPath: "m/44'/60'/\(i)'/0/0")
        }
        /// Per-origin Swarm publisher key for feed signing. Dedicated coin-type
        /// 73406 (matches desktop `derivation.js` `SWARM_PUBLISHER`) keeps these
        /// keys cryptographically isolated from the user wallet and the Bee
        /// node wallet — a publisher-key compromise can't drain user funds, and
        /// vice versa.
        static func publisherKey(originIndex i: Int) -> Path {
            precondition(
                i >= 0 && i < 0x8000_0000,
                "origin index \(i) out of range [0, 2³¹)"
            )
            return try! Path(rawPath: "m/44'/73406'/\(i)'/0/0")
        }
    }
}

extension Mnemonic {
    func hdKey(passphrase: String = "") throws -> HDKey {
        try HDKey(seed: seed(passphrase: passphrase))
    }
}
