import Foundation
import web3

/// GSOC (Graffiti Single Owner Chunk) topic → address derivation —
/// the "Freedom profile v1" pinned by desktop's `messaging-service.js`.
/// Byte-for-byte compatible with bee-js `gsocMine` as called there:
///
///     identifier    = keccak256(utf8(topic))
///     targetOverlay = keccak256(utf8("freedom-gsoc-v1:" + topic))
///     privateKey    = uint256BE(0xb33 + i), first i in [0, 0xffff)
///                     whose SOC address shares ≥ 12 leading bits
///                     with targetOverlay
///     address       = keccak256(identifier ‖ ownerAddress(privateKey))
///
/// Every constant here is FROZEN: any drift derives a different address
/// for the same topic and silently breaks room compatibility with
/// desktop Freedom (same-provider convergence is what the SWIP requires
/// and what the chat example relies on).
enum SwarmGsoc {
    /// Required shared leading bits between the mined SOC address and
    /// the topic's target overlay (bee-js `gsocMine` `proximity` arg).
    static let requiredProximityBits = 12
    /// Domain-separation prefix for the target-overlay derivation.
    static let targetContext = "freedom-gsoc-v1:"
    /// bee-js mining nonce base (`0xb33n`).
    static let nonceBase: UInt64 = 0xb33
    /// bee-js searches `i` in `[0, 0xffff)` and throws beyond it. At
    /// 12 required bits the expected hit is ~2¹² tries; exhausting
    /// 65535 is a ~e⁻¹⁶ event.
    static let maxIterations: UInt64 = 0xffff

    enum Error: Swift.Error, Equatable {
        /// No signer found within `maxIterations` — matches bee-js
        /// throwing "Could not mine GSOC" rather than looping forever.
        case miningExhausted
    }

    struct Derivation: Equatable {
        /// `keccak256(utf8(topic))` — the SOC identifier written to.
        let identifier: Data
        /// Mined owner private key (32 bytes). Deterministic per topic,
        /// derived from a public constant — holds NO secret value; it
        /// exists only to place the SOC in the right neighborhood.
        let privateKey: Data
        /// 64-hex lowercase SOC address `keccak256(identifier ‖ owner)`
        /// — the subscribe key and the `address` in sendGsoc results.
        let addressHex: String
    }

    /// Deterministic mine for `topic`. Pure CPU (expected ~4k
    /// keccak+secp256k1 rounds, tens of ms) — callers on the main
    /// actor should wrap in `Task.detached`; results are cached by
    /// `SwarmMessagingService`.
    static func derive(topic: String) throws -> Derivation {
        let identifier = Data(topic.utf8).web3.keccak256
        let targetOverlay = Data((targetContext + topic).utf8).web3.keccak256
        for i in 0..<maxIterations {
            var be = (nonceBase + i).bigEndian
            var key = Data(count: 24)
            key.append(withUnsafeBytes(of: &be) { Data($0) })
            // KeyUtil directly (not FeedSigner/EthereumAccount) — this
            // loop runs ~2¹² times per topic and only needs pubkey →
            // address, not a signing account.
            let publicKey = try KeyUtil.generatePublicKey(from: key)
            let owner = Data(publicKey.web3.keccak256.suffix(20))
            let address = SwarmSOC.socAddress(identifier: identifier, ownerAddress: owner)
            if proximityBits(address, targetOverlay) >= requiredProximityBits {
                return Derivation(
                    identifier: identifier,
                    privateKey: key,
                    addressHex: address.web3.hexString.web3.noHexPrefix
                )
            }
        }
        throw Error.miningExhausted
    }

    /// Leading identical bits between two equal-length byte strings —
    /// bee-js `Binary.proximity` (max 256 for 32-byte inputs).
    static func proximityBits(_ a: Data, _ b: Data) -> Int {
        var bits = 0
        for (x, y) in zip(a, b) {
            let diff = x ^ y
            if diff == 0 {
                bits += 8
            } else {
                bits += diff.leadingZeroBitCount
                break
            }
        }
        return bits
    }
}
