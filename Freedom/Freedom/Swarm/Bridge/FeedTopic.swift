import Foundation
import web3

/// Topic derivation for swarm feeds, byte-identical to desktop's
/// `buildTopicString` + bee-js's `Topic.fromString`:
/// `keccak256(origin + "/" + feedName)`, rendered as 64 lowercase hex
/// chars without `0x` prefix. Cross-platform parity is a hard
/// requirement — a user with the same mnemonic on iOS and desktop
/// must be able to read/write the same feed on both.
enum FeedTopic {
    static func derive(origin: String, name: String) -> String {
        fromString("\(origin)/\(name)")
    }

    /// bee-js `Topic.fromString` parity: keccak256 of the raw string, 64
    /// lowercase hex chars, no `0x`.
    static func fromString(_ string: String) -> String {
        Data(string.utf8).web3.keccak256.web3.hexString.web3.noHexPrefix
    }
}
