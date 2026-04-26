import Foundation
import web3

/// Native asset (`address == nil`) or recognised ERC-20.
struct Token: Equatable, Hashable, Identifiable {
    let chainID: Int
    let address: EthereumAddress?
    let symbol: String
    let name: String
    let decimals: Int
    let logoAsset: String?

    var id: String {
        if let address {
            return "\(chainID):\(address.asString().lowercased())"
        }
        return "\(chainID):native"
    }

    var isNative: Bool { address == nil }
}
