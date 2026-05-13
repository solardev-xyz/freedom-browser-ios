import Foundation
import web3

/// Shared ABI helpers for the ENS Universal Resolver. Keeps the address,
/// selector bytes, and `resolve(bytes,bytes)` encode/decode in one place
/// so the quorum path (`QuorumLeg`) and the Colibri path
/// (`ColibriENSClient`) can't drift on the call shape.
enum UniversalResolverABI {
    /// DAO-owned proxy so future UR impl upgrades don't require a client
    /// change. https://docs.ens.domains/resolvers/universal/
    static let address: EthereumAddress = "0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe"

    /// bytes4(keccak256("contenthash(bytes32)"))
    static let contenthashSelector = Data([0xbc, 0x1c, 0x58, 0xd1])

    /// bytes4(keccak256("addr(bytes32)"))
    static let addrSelector = Data([0x3b, 0x3b, 0x57, 0xde])

    /// `resolve(bytes name, bytes data)` — outer ABI envelope the UR
    /// expects. `name` is the DNS-encoded ENS name, `data` is the
    /// underlying resolver call (e.g. `contenthashSelector + namehash`).
    static func encodeResolve(name: Data, callData: Data) throws -> Data {
        let encoder = ABIFunctionEncoder("resolve")
        try encoder.encode(name)
        try encoder.encode(callData)
        return try encoder.encoded()
    }

    /// Decode the UR's `(bytes resolvedData, address resolver)` return.
    static func decodeResolveResponse(_ hex: String) throws -> (Data, EthereumAddress) {
        let decoded = try ABIDecoder.decodeData(hex, types: [Data.self, EthereumAddress.self])
        let data: Data = try decoded[0].decoded()
        let resolver: EthereumAddress = try decoded[1].decoded()
        return (data, resolver)
    }
}
