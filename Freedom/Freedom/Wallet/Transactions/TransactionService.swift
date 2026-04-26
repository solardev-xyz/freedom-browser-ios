import BigInt
import Foundation
import web3

/// Orchestrates build → sign → broadcast → confirm for a native-token
/// transfer. Pulls nonce from `NonceTracker`, fee from `GasOracle`, signs
/// via Argent's `EthereumAccount`, broadcasts + polls through `WalletRPC`.
///
/// Legacy (pre-EIP-1559) tx shape only in v1 — see `GasOracle.swift` for
/// the rationale.
@MainActor
@Observable
final class TransactionService {
    enum Error: Swift.Error, LocalizedError {
        case recipientInvalid
        case gasEstimateFailed
        case insufficientBalance
        case signingFailed
        case broadcastMalformed
        case confirmationTimeout

        var errorDescription: String? {
            switch self {
            case .recipientInvalid: return "Recipient isn't a valid Ethereum address."
            case .gasEstimateFailed: return "The network couldn't estimate gas — the transaction may be rejected. Check the recipient and amount."
            case .insufficientBalance: return "Not enough balance to cover the amount plus the network fee."
            case .signingFailed: return "Couldn't sign the transaction. Unlock the wallet and try again."
            case .broadcastMalformed: return "Signed transaction is malformed — please report this."
            case .confirmationTimeout: return "Transaction hasn't confirmed within the expected window. It may still land — check the explorer."
            }
        }
    }

    @ObservationIgnored let vault: Vault
    @ObservationIgnored let registry: ChainRegistry
    @ObservationIgnored let nonceTracker: NonceTracker
    @ObservationIgnored let gasOracle: GasOracle

    init(vault: Vault, registry: ChainRegistry) {
        self.vault = vault
        self.registry = registry
        self.nonceTracker = NonceTracker(rpc: registry.walletRPC)
        self.gasOracle = GasOracle(rpc: registry.walletRPC)
    }

    /// Translates a logical "send N of token T to recipient" into the
    /// `(to, value, data)` shape the EVM actually broadcasts. Native
    /// passes through; ERC-20 routes through the token contract with
    /// `transfer(recipient, amount)` calldata. Used by both quote
    /// preparation (so estimateGas sees the right params) and the
    /// broadcast itself (so the same params get signed).
    static func buildSend(
        token: Token,
        recipient: EthereumAddress,
        amount: BigUInt
    ) throws -> (to: EthereumAddress, value: BigUInt, data: Data) {
        if let contract = token.address {
            let calldata = try ERC20Coder.encodeTransfer(to: recipient, amount: amount)
            return (contract, 0, calldata)
        }
        return (recipient, amount, Data())
    }

    struct Quote {
        let from: EthereumAddress
        let nonce: Int
        let gasPrice: BigUInt
        let gasLimit: BigUInt

        /// Worst-case fee the user pays for this tx. Computed to avoid
        /// drift if callers mutate the underlying gas fields.
        var maxFeeWei: BigUInt { gasPrice * gasLimit }
    }

    /// Fetch nonce + gas price + gas estimate in parallel — independent RPCs,
    /// no reason to serialise. Call once before showing the review screen.
    /// `data` is required (not defaulted) — silent omission for a contract
    /// call would broadcast a value-only tx, the worst class of correctness
    /// bug. Native-send callers pass `Data()` explicitly.
    func prepare(
        from: EthereumAddress,
        to: EthereumAddress,
        valueWei: BigUInt,
        data: Data,
        on chain: Chain
    ) async throws -> Quote {
        async let nonce = nonceTracker.next(for: from.asString(), on: chain)
        async let gasPriceWei = gasOracle.suggestedGasPrice(on: chain)
        async let gasLimitHex = registry.walletRPC.estimateGas(
            from: from.asString(),
            to: to.asString(),
            valueHex: "0x" + String(valueWei, radix: 16),
            // Data.web3.hexString prefixes; concatenating "0x" yields "0x0x".
            dataHex: data.isEmpty ? "0x" : data.web3.hexString,
            on: chain
        )
        do {
            guard let gasLimit = Hex.bigUInt(try await gasLimitHex) else {
                throw Error.gasEstimateFailed
            }
            return Quote(
                from: from,
                nonce: try await nonce,
                gasPrice: try await gasPriceWei,
                gasLimit: gasLimit
            )
        } catch WalletRPC.Error.insufficientFunds {
            // Don't leak WalletRPC internals into the UI — the send flow
            // catches `TransactionService.Error` only.
            throw Error.insufficientBalance
        }
    }

    /// Build → sign → broadcast. Caller pre-committed to `quote`. Returns
    /// the tx hash on success; on broadcast failure the nonce is
    /// invalidated so the next `prepare` re-fetches from chain.
    func send(
        to: EthereumAddress,
        valueWei: BigUInt,
        data: Data,
        quote: Quote,
        on chain: Chain
    ) async throws -> String {
        let account = try vault.signingAccount()

        let tx = EthereumTransaction(
            from: quote.from,
            to: to,
            value: valueWei,
            data: data,
            nonce: quote.nonce,
            gasPrice: quote.gasPrice,
            gasLimit: quote.gasLimit,
            chainId: chain.id
        )

        let signed: SignedTransaction
        do {
            signed = try account.sign(transaction: tx)
        } catch {
            throw Error.signingFailed
        }
        guard let raw = signed.raw else { throw Error.broadcastMalformed }

        do {
            // `raw.web3.hexString` already includes the `0x` prefix;
            // prepending another is how we shipped "0x0x..." as the RPC
            // param and got -32602 back. Don't.
            let hash = try await registry.walletRPC.sendRawTransaction(
                rawHex: raw.web3.hexString,
                on: chain
            )
            nonceTracker.markSent(address: quote.from.asString(), on: chain, usedNonce: quote.nonce)
            return hash
        } catch {
            nonceTracker.invalidate(address: quote.from.asString(), on: chain)
            throw error
        }
    }

    /// Polls `eth_getTransactionByHash` until `blockNumber` is populated,
    /// or the timeout elapses. Returns the confirming block number on
    /// success. Respects `Task.isCancelled` so the caller can bail if
    /// the view goes away. Poll interval defaults to the chain's block
    /// time — polling faster than block production wastes RPCs.
    func awaitConfirmation(
        hash: String,
        on chain: Chain,
        pollInterval: Duration? = nil,
        timeout: Duration = .seconds(180)
    ) async throws -> Int {
        let interval = pollInterval ?? chain.pollInterval
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let tx = try await registry.walletRPC.getTransaction(hash: hash, on: chain),
               let blockHex = tx.blockNumber,
               let block = Hex.int(blockHex) {
                return block
            }
            try? await Task.sleep(for: interval)
        }
        throw Error.confirmationTimeout
    }
}
