import Foundation

/// Decodes `wallet_switchEthereumChain` params: `[{chainId: "0x64"}]`.
enum SwitchChainParamsCoder {
    enum Error: Swift.Error {
        case badParams
    }

    static func decodeChainID(params: [Any]) throws -> Int {
        guard let first = params.first,
              let dict = first as? [String: Any],
              let raw = dict["chainId"] as? String,
              let id = Hex.int(raw) else {
            throw Error.badParams
        }
        return id
    }
}
