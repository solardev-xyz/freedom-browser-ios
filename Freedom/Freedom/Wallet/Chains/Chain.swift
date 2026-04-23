import Foundation

struct Chain: Equatable, Hashable, Identifiable {
    let id: Int
    let displayName: String
    let explorerBase: URL
    let nativeSymbol: String

    /// EIP-155 chain ID, `0x`-prefixed hex (EIP-1193 wire format).
    var hexChainID: String { "0x" + String(id, radix: 16) }

    static let mainnet = Chain(
        id: 1,
        displayName: "Ethereum",
        explorerBase: URL(string: "https://etherscan.io")!,
        nativeSymbol: "ETH"
    )

    static let gnosis = Chain(
        id: 100,
        displayName: "Gnosis Chain",
        explorerBase: URL(string: "https://gnosisscan.io")!,
        nativeSymbol: "xDAI"
    )

    static let all: [Chain] = [.gnosis, .mainnet]
    static let defaultChain: Chain = .gnosis
}
