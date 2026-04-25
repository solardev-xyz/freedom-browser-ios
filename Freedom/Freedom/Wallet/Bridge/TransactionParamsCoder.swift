import BigInt
import Foundation
import web3

/// Decodes the `eth_sendTransaction` params: a single tx-object dict with
/// hex-encoded fields. `from` and `to` are required; everything else is
/// optional and either defaults (zero/empty) or estimates downstream.
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
    }

    static func decode(params: [Any]) throws -> Decoded {
        guard let first = params.first, let tx = first as? [String: Any] else {
            throw Error.badParams
        }
        guard let fromHex = tx["from"] as? String else { throw Error.missingFrom }
        guard let toHex = tx["to"] as? String else { throw Error.missingTo }
        let from = try address(fromHex)
        let to = try address(toHex)

        let valueWei: BigUInt = try Hex.optionalBigUInt(tx["value"], field: "value") ?? 0

        let data: Data
        if let raw = tx["data"] as? String, !raw.isEmpty, raw != "0x" {
            guard let bytes = raw.web3.hexData else {
                throw Hex.Error.invalidHex(field: "data", value: raw)
            }
            data = bytes
        } else {
            data = Data()
        }

        return Decoded(
            from: from,
            to: to,
            valueWei: valueWei,
            data: data,
            gasLimit: try Hex.optionalBigUInt(tx["gas"], field: "gas"),
            gasPriceWei: try Hex.optionalBigUInt(tx["gasPrice"], field: "gasPrice"),
            nonce: try Hex.optionalInt(tx["nonce"], field: "nonce"),
            chainID: try Hex.optionalInt(tx["chainId"], field: "chainId")
        )
    }

    private static func address(_ raw: String) throws -> EthereumAddress {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Hex.isAddressShape(trimmed) else {
            throw Error.invalidAddress(raw)
        }
        return EthereumAddress(trimmed)
    }
}
