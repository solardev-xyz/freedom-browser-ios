import BigInt
import Foundation
import SwiftData
import web3

/// Who initiated the transaction — desktop's payment-history `KINDS`
/// restricted to what iOS signs today.
enum WalletTransactionKind: String, Codable, CaseIterable {
    /// The wallet's own Send flow.
    case walletSend = "wallet-send"
    /// A dapp's `eth_sendTransaction` through the EIP-1193 bridge.
    case dappSend = "dapp-send"
}

/// Desktop's `STATUSES` for broadcast transactions: born pending, then
/// confirmed or failed once a receipt lands.
enum WalletTransactionStatus: String, Codable, CaseIterable {
    case pending
    case confirmed
    case failed
}

/// One outgoing transaction the wallet signed and broadcast — desktop's
/// payment-history row (`src/main/payment-history.js`). Recorded right
/// after the broadcast returns a hash, finalized when the receipt lands;
/// a row still pending at launch is re-polled once.
///
/// `toAddress` / `amount` / `asset*` describe what the user sees (the
/// ERC-20 recipient and amount for a token transfer, not the contract
/// and the zero value the EVM saw). The asset's symbol and decimals are
/// snapshotted so the row stays readable after a token disappears from
/// the registry.
@Model
final class WalletTransactionRecord {
    @Attribute(.unique) var id: UUID
    var kind: WalletTransactionKind
    var chainID: Int
    var txHash: String
    var fromAddress: String
    var toAddress: String
    /// ERC-20 contract, nil for the chain's native asset.
    var assetAddress: String?
    var assetSymbol: String
    var assetDecimals: Int
    /// Atomic units as a decimal digit string (desktop's schema; SwiftData
    /// has no 256-bit integer).
    var amount: String
    /// Permission key of the dapp that asked, nil for the wallet's own sends.
    var origin: String?
    var status: WalletTransactionStatus
    var createdAt: Date
    var confirmedAt: Date?
    /// Hex quantities from the receipt.
    var gasUsed: String?
    var gasPrice: String?
    var failureReason: String?

    init(
        id: UUID = UUID(),
        kind: WalletTransactionKind,
        chainID: Int,
        txHash: String,
        fromAddress: String,
        toAddress: String,
        assetAddress: String?,
        assetSymbol: String,
        assetDecimals: Int,
        amount: BigUInt,
        origin: String?,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.chainID = chainID
        self.txHash = txHash
        self.fromAddress = fromAddress
        self.toAddress = toAddress
        self.assetAddress = assetAddress
        self.assetSymbol = assetSymbol
        self.assetDecimals = assetDecimals
        self.amount = String(amount)
        self.origin = origin
        self.status = .pending
        self.createdAt = createdAt
    }

    var amountValue: BigUInt { BigUInt(amount) ?? 0 }

    /// The asset as the formatter wants it.
    var token: Token {
        Token(
            chainID: chainID,
            address: assetAddress.flatMap { EthereumAddress($0) },
            symbol: assetSymbol, name: assetSymbol, decimals: assetDecimals, logoAsset: nil
        )
    }
}

/// What a caller knows about a send beyond the raw `(to, value, data)`
/// the EVM sees — desktop's `signAndRecord` context.
struct WalletTransactionContext: Equatable {
    let kind: WalletTransactionKind
    /// Human-visible recipient (the ERC-20 recipient for a token transfer).
    let toAddress: String
    let assetAddress: String?
    let assetSymbol: String
    let assetDecimals: Int
    /// Human-visible amount in atomic units.
    let amount: BigUInt
    var origin: String? = nil

    /// A native send, or an ERC-20 `transfer(to, amount)` decoded from
    /// the calldata — what a dapp's `eth_sendTransaction` reduces to.
    static func describing(
        kind: WalletTransactionKind, to: EthereumAddress, valueWei: BigUInt, data: Data,
        chain: Chain, tokens: [Token], origin: String?
    ) -> WalletTransactionContext {
        if let transfer = ERC20Coder.decodeTransfer(data: data) {
            let contract = to.asString().lowercased()
            let known = tokens.first { $0.address?.asString().lowercased() == contract }
            return WalletTransactionContext(
                kind: kind, toAddress: transfer.to.asString(),
                assetAddress: to.asString(), assetSymbol: known?.symbol ?? "token",
                assetDecimals: known?.decimals ?? 18, amount: transfer.amount, origin: origin
            )
        }
        return WalletTransactionContext(
            kind: kind, toAddress: to.asString(), assetAddress: nil,
            assetSymbol: chain.nativeSymbol, assetDecimals: chain.nativeDecimals,
            amount: valueWei, origin: origin
        )
    }
}
