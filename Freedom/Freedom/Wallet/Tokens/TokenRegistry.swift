import Foundation
import web3

/// Logo asset names follow `token-{symbol}` for chain-shared logos
/// (BZZ/xBZZ) and `token-{symbol}-{chain}` for per-chain stablecoin
/// variants (USDC has different logos on different L2s).
enum TokenRegistry {
    static let builtins: [Token] = [
        // Mainnet
        Token(
            chainID: 1, address: nil,
            symbol: "ETH", name: "Ether", decimals: 18,
            logoAsset: "token-eth"
        ),
        Token(
            chainID: 1,
            address: EthereumAddress("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"),
            symbol: "USDC", name: "USD Coin", decimals: 6,
            logoAsset: "token-usdc-eth"
        ),
        Token(
            chainID: 1,
            address: EthereumAddress("0xdAC17F958D2ee523a2206206994597C13D831ec7"),
            symbol: "USDT", name: "Tether USD", decimals: 6,
            logoAsset: "token-usdt-eth"
        ),
        Token(
            chainID: 1,
            address: EthereumAddress("0x6B175474E89094C44Da98b954EedeAC495271d0F"),
            symbol: "DAI", name: "Dai Stablecoin", decimals: 18,
            logoAsset: "token-dai-eth"
        ),
        Token(
            chainID: 1,
            address: EthereumAddress("0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c"),
            symbol: "EURC", name: "Euro Coin", decimals: 6,
            logoAsset: "token-eurc-eth"
        ),
        Token(
            chainID: 1,
            address: EthereumAddress("0x19062190B1925b5b6689D7073fDfC8c2976EF8Cb"),
            symbol: "BZZ", name: "Swarm Token", decimals: 16,
            logoAsset: "token-bzz"
        ),
        // Gnosis
        Token(
            chainID: 100, address: nil,
            symbol: "xDAI", name: "xDAI", decimals: 18,
            logoAsset: "token-xdai"
        ),
        Token(
            chainID: 100,
            address: EthereumAddress("0xdBF3Ea6F5beE45c02255B2c26a16F300502F68da"),
            symbol: "xBZZ", name: "Swarm Token", decimals: 16,
            logoAsset: "token-bzz"
        ),
        Token(
            chainID: 100,
            address: EthereumAddress("0x420CA0f9B9b604cE0fd9C18EF134C705e5Fa3430"),
            symbol: "EURe", name: "Monerium EUR emoney", decimals: 18,
            logoAsset: "token-eure"
        ),
    ]

    /// Native first (consistent placement at the top of the asset list),
    /// then ERC-20s in the order declared above.
    static func tokens(for chain: Chain) -> [Token] {
        builtins.filter { $0.chainID == chain.id }
    }

    static func native(for chain: Chain) -> Token? {
        builtins.first { $0.chainID == chain.id && $0.address == nil }
    }
}
