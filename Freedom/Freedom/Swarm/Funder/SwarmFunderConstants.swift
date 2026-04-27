import BigInt
import Foundation
import web3

/// Pinned constants for the `SwarmNodeFunder` one-tx upgrade flow on Gnosis.
/// Mirrors `freedom-browser/src/shared/swarm-funder.js` from the contributor's
/// `oneclick-setup` branch — same addresses, same parameters, same math, so
/// the iOS quote + tx output is byte-identical to desktop's for any given
/// input.
///
/// If the contributor redeploys the funder (audit fix, parameter tweak), we
/// ship a new address + ABI in a point release. Stateless, admin-less per
/// the contract notes.
enum SwarmFunderConstants {
    static let chainID: Int = 100  // Gnosis

    /// Deployed 2026-04-24, verified on Blockscout.
    static let funderAddress: EthereumAddress =
        "0x508994B55C53E84d2d600A55da05f751aEf658d2"

    /// UniswapV3 0.3% BZZ/WXDAI pool — deepest BZZ pool on Gnosis at the
    /// time of writing (~$2K TVL). Token order: token0 = BZZ (16 dec),
    /// token1 = WXDAI (18 dec).
    static let poolAddress: EthereumAddress =
        "0x7583b9C573FA4FB5Ea21C83454939c4Cf6aacBc3"

    /// Pool fee in basis points (0.3%). Used to discount `expectedBzzOut`.
    static let poolFeeBps: Int = 30

    static let bzzToken: EthereumAddress =
        "0xdBF3Ea6F5beE45c02255B2c26a16F300502F68da"
    static let wxdaiToken: EthereumAddress =
        "0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d"

    static let bzzDecimals: Int = 16
    static let wxdaiDecimals: Int = 18

    /// 5% — the slippage guard we apply to `expectedBzzOut` to compute
    /// `minBzzOut`. Swap larger than the pool can absorb at this tolerance
    /// reverts cleanly with `minBzzOut not met`; user pays gas, no tokens
    /// lost. Hardcoded; if real users hit slippage failures we'll surface
    /// it as an advanced setting.
    static let defaultSlippageBps: Int = 500

    /// Fixed amount forwarded to the bee wallet to cover its chequebook-
    /// deploy gas. 0.05 xDAI is desktop's default and comfortably above
    /// the Gnosis chequebook deploy cost (~0.005 xDAI today).
    static let xdaiForBeeWei: BigUInt = BigUInt(50_000_000_000_000_000)  // 0.05 ether

    /// Pinned Gnosis RPC for bee-lite's `blockchainRpcEndpoint` when
    /// running in light mode. Decoupled from `ChainRegistry`'s Gnosis
    /// list (used for our own eth_calls) so the two paths can drift
    /// independently if either provider migrates.
    static let pinnedGnosisRPC: String = "https://rpc.gnosischain.com"
}
