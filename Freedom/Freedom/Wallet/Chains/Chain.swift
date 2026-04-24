import Foundation

struct Chain: Equatable, Hashable, Identifiable {
    let id: Int
    let displayName: String
    let explorerBase: URL
    let nativeSymbol: String
    /// Target block time — `TransactionService.awaitConfirmation` uses this
    /// as its default polling interval, so we don't fire faster than blocks
    /// actually produce.
    let pollInterval: Duration

    /// EIP-155 chain ID, `0x`-prefixed hex (EIP-1193 wire format).
    var hexChainID: String { "0x" + String(id, radix: 16) }

    /// Block-explorer URL for a tx hash. Keeps the `/tx/` path convention
    /// here rather than leaking it into every view that wants to link out.
    func explorerURL(forTx hash: String) -> URL {
        explorerBase.appendingPathComponent("tx").appendingPathComponent(hash)
    }

    static let mainnet = Chain(
        id: 1,
        displayName: "Ethereum",
        explorerBase: URL(string: "https://etherscan.io")!,
        nativeSymbol: "ETH",
        pollInterval: .seconds(8)
    )

    static let gnosis = Chain(
        id: 100,
        displayName: "Gnosis Chain",
        explorerBase: URL(string: "https://gnosisscan.io")!,
        nativeSymbol: "xDAI",
        pollInterval: .seconds(3)
    )

    static let all: [Chain] = [.gnosis, .mainnet]
    static let defaultChain: Chain = .gnosis

    static func find(id: Int) -> Chain? {
        all.first(where: { $0.id == id })
    }
}
