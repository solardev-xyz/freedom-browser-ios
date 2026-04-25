import BigInt
import Foundation
import web3

/// Decodes the `eth_sendTransaction` params: a single tx-object dict with
/// hex-encoded fields. `from` and `to` are the only required fields; the
/// dapp may omit any of `value`, `data`, `gas`, `gasPrice`, `nonce`,
/// `chainId`, in which case we fill in defaults (zero/empty) or estimate
/// downstream.
enum TransactionParamsCoder {
    struct Decoded {
        let from: EthereumAddress
        let to: EthereumAddress
        let valueWei: BigUInt
        let data: Data
        // Dapp-supplied overrides — bridge prefers these over fresh estimates.
        let gasLimit: BigUInt?
        let gasPriceWei: BigUInt?
        let nonce: Int?
        let chainID: Int?
    }

    enum Error: Swift.Error {
        case badParams
        case missingFrom
        case missingTo
        case invalidAddress(String)
        case invalidHex(field: String, value: String)
    }

    static func decode(params: [Any]) throws -> Decoded {
        guard let first = params.first, let tx = first as? [String: Any] else {
            throw Error.badParams
        }
        guard let fromHex = tx["from"] as? String else { throw Error.missingFrom }
        guard let toHex = tx["to"] as? String else { throw Error.missingTo }
        let from = try address(fromHex)
        let to = try address(toHex)

        let valueWei: BigUInt
        if let raw = tx["value"] as? String {
            guard let parsed = parseBigUInt(raw) else {
                throw Error.invalidHex(field: "value", value: raw)
            }
            valueWei = parsed
        } else {
            valueWei = 0
        }

        let data: Data
        if let raw = tx["data"] as? String, !raw.isEmpty, raw != "0x" {
            guard let bytes = raw.web3.hexData else {
                throw Error.invalidHex(field: "data", value: raw)
            }
            data = bytes
        } else {
            data = Data()
        }

        let gasLimit = try optionalBigUInt(tx["gas"], field: "gas")
        let gasPriceWei = try optionalBigUInt(tx["gasPrice"], field: "gasPrice")
        let nonce = try optionalInt(tx["nonce"], field: "nonce")
        let chainID = try optionalInt(tx["chainId"], field: "chainId")

        return Decoded(
            from: from, to: to, valueWei: valueWei, data: data,
            gasLimit: gasLimit, gasPriceWei: gasPriceWei,
            nonce: nonce, chainID: chainID
        )
    }

    private static func address(_ raw: String) throws -> EthereumAddress {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 42,
              trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X"),
              trimmed.dropFirst(2).allSatisfy(\.isHexDigit) else {
            throw Error.invalidAddress(raw)
        }
        return EthereumAddress(trimmed)
    }

    private static func parseBigUInt(_ raw: String) -> BigUInt? {
        Hex.bigUInt(raw)
    }

    private static func optionalBigUInt(_ value: Any?, field: String) throws -> BigUInt? {
        guard let raw = value as? String else { return nil }
        guard let parsed = parseBigUInt(raw) else {
            throw Error.invalidHex(field: field, value: raw)
        }
        return parsed
    }

    private static func optionalInt(_ value: Any?, field: String) throws -> Int? {
        guard let raw = value as? String else { return nil }
        guard let parsed = Hex.int(raw) else {
            throw Error.invalidHex(field: field, value: raw)
        }
        return parsed
    }
}
