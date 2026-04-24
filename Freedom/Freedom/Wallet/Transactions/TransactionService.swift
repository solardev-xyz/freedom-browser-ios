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
    enum Error: Swift.Error {
        case recipientInvalid
        case gasEstimateFailed
        case signingFailed
        case broadcastMalformed
        case confirmationTimeout
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
    func prepare(
        from: EthereumAddress,
        to: EthereumAddress,
        valueWei: BigUInt,
        on chain: Chain
    ) async throws -> Quote {
        async let nonce = nonceTracker.next(for: from.asString(), on: chain)
        async let gasPriceWei = gasOracle.suggestedGasPrice(on: chain)
        async let gasLimitHex = registry.walletRPC.estimateGas(
            from: from.asString(),
            to: to.asString(),
            valueHex: "0x" + String(valueWei, radix: 16),
            dataHex: "0x",
            on: chain
        )
        guard let gasLimit = Hex.bigUInt(try await gasLimitHex) else {
            throw Error.gasEstimateFailed
        }
        return Quote(
            from: from,
            nonce: try await nonce,
            gasPrice: try await gasPriceWei,
            gasLimit: gasLimit
        )
    }

    /// Build → sign → broadcast. Caller pre-committed to `quote`. Returns
    /// the tx hash on success; on broadcast failure the nonce is
    /// invalidated so the next `prepare` re-fetches from chain.
    func send(
        to: EthereumAddress,
        valueWei: BigUInt,
        quote: Quote,
        on chain: Chain
    ) async throws -> String {
        let hdKey = try vault.signingKey(at: .mainUser)
        let account = try EthereumAccount(keyStorage: HDKeyStorage(privateKey: hdKey.privateKey))

        let tx = EthereumTransaction(
            from: quote.from,
            to: to,
            value: valueWei,
            data: Data(),
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
            let hash = try await registry.walletRPC.sendRawTransaction(
                rawHex: "0x" + raw.web3.hexString,
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
