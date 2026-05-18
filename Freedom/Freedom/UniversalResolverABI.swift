import BigInt
import Foundation
import web3

/// Shared ABI helpers for the ENS Universal Resolver. Keeps the address,
/// selector bytes, and `resolve(bytes,bytes)` / `reverse(bytes,uint256)`
/// encode/decode in one place so the quorum path (`QuorumLeg`,
/// `ENSResolver`) and the Colibri path (`ColibriENSClient`) can't drift
/// on the call shape.
enum UniversalResolverABI {
    /// DAO-owned proxy so future UR impl upgrades don't require a client
    /// change. https://docs.ens.domains/resolvers/universal/
    static let address: EthereumAddress = "0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe"

    /// bytes4(keccak256("contenthash(bytes32)"))
    static let contenthashSelector = Data([0xbc, 0x1c, 0x58, 0xd1])

    /// bytes4(keccak256("addr(bytes32)"))
    static let addrSelector = Data([0x3b, 0x3b, 0x57, 0xde])

    /// SLIP-44 coin type for Ethereum mainnet. Second arg to UR's
    /// `reverse(bytes,uint256)` — picks the canonical Ethereum-address
    /// primary name vs. other-chain primary names.
    static let ethereumCoinType: BigUInt = 60

    /// UR custom-error selector for `ReverseAddressMismatch(string,bytes)`.
    /// The contract reverts with this when an address's reverse record
    /// claims a primary name that doesn't forward-resolve back to the
    /// address — the spoof signal. First ABI arg is the claimed name.
    static let reverseAddressMismatchSelector = Data([0xef, 0x9c, 0x03, 0xce])

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

    /// `reverse(bytes addressBytes, uint256 coinType)` — UR call shape.
    /// `addressBytes` is the 20-byte address; `coinType` defaults to
    /// `ethereumCoinType` (60) for mainnet primary names.
    static func encodeReverse(address: EthereumAddress, coinType: BigUInt = ethereumCoinType) throws -> Data {
        guard let addressBytes = address.asString().web3.hexData else {
            throw NSError(domain: "UniversalResolverABI", code: 1)
        }
        let encoder = ABIFunctionEncoder("reverse")
        try encoder.encode(addressBytes)
        try encoder.encode(coinType)
        return try encoder.encoded()
    }

    /// Decode the UR's `(string primary, address resolver, address reverseResolver)`
    /// return from `reverse()`.
    static func decodeReverseResponse(_ hex: String) -> String? {
        guard let decoded = try? ABIDecoder.decodeData(
            hex, types: [String.self, EthereumAddress.self, EthereumAddress.self]
        ), let primary = try? decoded[0].decoded() as String else {
            return nil
        }
        return primary
    }

    /// True if `revertHex` is a `ReverseAddressMismatch` revert (selector
    /// match only; doesn't require parseable args). Pass either form
    /// (`0x…` or bare hex) — `lowercased` happens once here.
    static func isReverseAddressMismatch(revertHex: String) -> Bool {
        let lower = revertHex.lowercased()
        let stripped = lower.hasPrefix("0x") ? lower.dropFirst(2) : lower[...]
        guard stripped.count >= 8 else { return false }
        return stripped.prefix(8) == reverseAddressMismatchSelector.web3.hexString.web3.noHexPrefix
    }

    /// Decode the claimed name out of a `ReverseAddressMismatch(string,bytes)`
    /// revert. Returns nil for non-mismatch reverts or malformed args —
    /// callers fall back to a nameless `.unverified` outcome on the
    /// "selector matches but args don't parse" case.
    static func decodeReverseMismatchClaimedName(revertHex: String) -> String? {
        guard isReverseAddressMismatch(revertHex: revertHex) else { return nil }
        let lower = revertHex.lowercased()
        let stripped = lower.hasPrefix("0x") ? lower.dropFirst(2) : lower[...]
        let argsHex = "0x" + stripped.dropFirst(8)
        guard let decoded = try? ABIDecoder.decodeData(
            argsHex, types: [String.self, Data.self]
        ), let name = try? decoded[0].decoded() as String else {
            return nil
        }
        return name.isEmpty ? nil : name
    }
}
