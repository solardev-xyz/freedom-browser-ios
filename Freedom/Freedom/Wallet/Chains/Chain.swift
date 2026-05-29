import Foundation

struct Chain: Equatable, Hashable, Identifiable {
    let id: Int
    let displayName: String
    let explorerBase: URL
    let nativeName: String
    let nativeSymbol: String
    let nativeDecimals: Int
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

    /// Canonical EIP-155 IDs for the protocol-pinned chains. ENS and Colibri
    /// resolve only against mainnet; the active-chain default falls back to
    /// Gnosis. Surfaced as constants so call sites that must hard-pin don't
    /// depend on the value-type `static let`s sticking around forever.
    static let mainnetID = 1
    static let gnosisID = 100

    static let mainnet = Chain(
        id: Self.mainnetID,
        displayName: "Ethereum",
        explorerBase: URL(string: "https://etherscan.io")!,
        nativeName: "Ether",
        nativeSymbol: "ETH",
        nativeDecimals: 18,
        pollInterval: .seconds(8)
    )

    static let gnosis = Chain(
        id: Self.gnosisID,
        displayName: "Gnosis Chain",
        explorerBase: URL(string: "https://gnosisscan.io")!,
        nativeName: "xDAI",
        nativeSymbol: "xDAI",
        nativeDecimals: 18,
        pollInterval: .seconds(3)
    )

    static let all: [Chain] = [.gnosis, .mainnet]
    static let defaultChain: Chain = .gnosis

    static func find(id: Int) -> Chain? {
        all.first(where: { $0.id == id })
    }
}
