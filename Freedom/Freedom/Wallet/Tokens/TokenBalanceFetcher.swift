import BigInt
import Foundation
import web3

/// Fetches per-asset balances for a `(holder, chain)` over the wallet's
/// existing single-shot-with-fallback RPC. Native goes through
/// `eth_getBalance`; each ERC-20 fires its own `eth_call(balanceOf)` in
/// parallel via `withTaskGroup`. Tokens whose call fails are absent
/// from the result map (not present ≠ zero) — caller treats absence as
/// "skip in UI".
@MainActor
struct TokenBalanceFetcher {
    let walletRPC: WalletRPC

    func fetch(
        holder: EthereumAddress,
        chain: Chain,
        tokens: [Token]
    ) async -> [Token: BigUInt] {
        await withTaskGroup(of: (Token, BigUInt?).self) { group in
            for token in tokens {
                group.addTask {
                    let value = await fetchOne(holder: holder, chain: chain, token: token)
                    return (token, value)
                }
            }
            var result: [Token: BigUInt] = [:]
            for await (token, value) in group {
                if let value { result[token] = value }
            }
            return result
        }
    }

    private func fetchOne(holder: EthereumAddress, chain: Chain, token: Token) async -> BigUInt? {
        do {
            if let address = token.address {
                let callData = try ERC20Coder.encodeBalanceOf(holder: holder)
                let tx: [String: String] = [
                    "to": address.asString(),
                    "data": callData.web3.hexString,
                ]
                let raw = try await walletRPC.callJSON(
                    method: "eth_call", params: [tx, "latest"], on: chain
                )
                guard let hex = raw as? String else { return nil }
                return ERC20Coder.decodeBalance(hex: hex)
            } else {
                let hex = try await walletRPC.balance(of: holder.asString(), on: chain)
                return Hex.bigUInt(hex)
            }
        } catch {
            return nil
        }
    }
}
