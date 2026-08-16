import Foundation
import FreedomMobile

/// Verified wallet-read surface over the engine's C ABI, mirroring the
/// desktop chain-data-router's use of the napi addon (same fallback keys
/// in the decoders). All calls are blocking in the engine and run
/// detached; every outcome decoder is pure and unit-tested.

/// Account read: `{"balanceWei"|"balance", "nonce", ...}` or `{"error"}`.
public enum MyotisAccountOutcome: Sendable, Equatable {
    case ok(balanceWei: String, nonce: UInt64)
    case unavailable(reason: String)

    public static func decode(_ json: String) -> MyotisAccountOutcome {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return .unavailable(reason: "undecodable account response")
        }
        if let error = obj["error"] as? String { return .unavailable(reason: error) }
        let balance = (obj["balanceWei"] ?? obj["balance"]).flatMap(decimalString)
        let nonce = obj["nonce"].flatMap(uint64Value)
        guard let balance, let nonce else {
            return .unavailable(reason: "account response missing balance/nonce")
        }
        return .ok(balanceWei: balance, nonce: nonce)
    }
}

/// Fee estimate: `{"gasPriceWei","maxPriorityFeePerGasWei"}` or `{"error"}`.
public enum MyotisFeeOutcome: Sendable, Equatable {
    case ok(gasPriceWei: String, maxPriorityFeePerGasWei: String?)
    case unavailable(reason: String)

    public static func decode(_ json: String) -> MyotisFeeOutcome {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return .unavailable(reason: "undecodable fee response")
        }
        if let error = obj["error"] as? String { return .unavailable(reason: error) }
        guard let gasPrice = (obj["gasPriceWei"] ?? obj["gasPrice"]).flatMap(decimalString) else {
            return .unavailable(reason: "fee response missing gas price")
        }
        let priority = (obj["maxPriorityFeePerGasWei"] ?? obj["maxPriorityFeePerGas"])
            .flatMap(decimalString)
        return .ok(gasPriceWei: gasPrice, maxPriorityFeePerGasWei: priority)
    }
}

/// Gas estimate: `{"status":"ok","gas":N}` | `{"status":"revert","dataHex"}`
/// | `{"status":"unavailable","reason"}` | `{"error"}`.
public enum MyotisGasOutcome: Sendable, Equatable {
    case ok(gas: UInt64)
    /// The estimated transaction reverted over verified state — a
    /// verified chain answer (serve JSON-RPC code 3), not a failure.
    case revert(dataHex: String)
    case unavailable(reason: String)

    public static func decode(_ json: String) -> MyotisGasOutcome {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return .unavailable(reason: "undecodable gas response")
        }
        if let error = obj["error"] as? String { return .unavailable(reason: error) }
        switch obj["status"] as? String {
        case "ok":
            guard let gas = (obj["gas"] ?? obj["gasLimit"]).flatMap(uint64Value) else {
                return .unavailable(reason: "gas response missing gas")
            }
            return .ok(gas: gas)
        case "revert":
            return .revert(dataHex: obj["dataHex"] as? String ?? "0x")
        case "unavailable":
            return .unavailable(reason: obj["reason"] as? String ?? "unavailable")
        default:
            return .unavailable(reason: "unexpected gas response: \(json)")
        }
    }
}

/// Broadcast: `{"txHash":"0x…"}` or `{"error"}`.
public enum MyotisBroadcastOutcome: Sendable, Equatable {
    case ok(txHash: String)
    case failed(message: String)

    public static func decode(_ json: String) -> MyotisBroadcastOutcome {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return .failed(message: "undecodable broadcast response")
        }
        if let error = obj["error"] as? String { return .failed(message: error) }
        guard let hash = (obj["txHash"] ?? obj["result"]) as? String else {
            return .failed(message: "broadcast response missing txHash")
        }
        return .ok(txHash: hash)
    }
}

/// Accept the engine's numeric encodings (JSON number, decimal string,
/// 0x-hex string) and normalize to a decimal string / UInt64.
private func decimalString(_ value: Any) -> String? {
    if let n = value as? NSNumber { return n.stringValue }
    guard let s = value as? String else { return nil }
    if s.lowercased().hasPrefix("0x"), let v = UInt64(s.dropFirst(2), radix: 16) {
        return String(v)
    }
    return s.allSatisfy(\.isNumber) && !s.isEmpty ? s : nil
}

private func uint64Value(_ value: Any) -> UInt64? {
    if let n = value as? NSNumber { return n.uint64Value }
    guard let s = value as? String else { return nil }
    if s.lowercased().hasPrefix("0x") { return UInt64(s.dropFirst(2), radix: 16) }
    return UInt64(s)
}

extension MyotisNode {
    /// Verified balance + mined nonce from proof-served head state.
    public func requestAccount(chainId: UInt64, address: String) async -> MyotisAccountOutcome {
        guard let handle = runningHandle(chainId: chainId) else {
            return .unavailable(reason: "node not running for chain \(chainId)")
        }
        let json = await Task.detached(priority: .userInitiated) {
            address.withCString { Self.takeString(myotis_request_account_json(handle, $0)) }
        }.value
        guard let json else { return .unavailable(reason: "engine returned NULL") }
        return MyotisAccountOutcome.decode(json)
    }

    /// Verified fee estimate for the chain's current head.
    public func feeEstimate(chainId: UInt64) async -> MyotisFeeOutcome {
        guard let handle = runningHandle(chainId: chainId) else {
            return .unavailable(reason: "node not running for chain \(chainId)")
        }
        let json = await Task.detached(priority: .userInitiated) {
            Self.takeString(myotis_fee_estimate_json(handle))
        }.value
        guard let json else { return .unavailable(reason: "engine returned NULL") }
        return MyotisFeeOutcome.decode(json)
    }

    /// Gas estimate over verified head state (from/to/data/value only —
    /// callers must gate richer call shapes to another source).
    public func estimateGas(
        chainId: UInt64, from: String = "", to: String, data: String, value: String = "0"
    ) async -> MyotisGasOutcome {
        guard let handle = runningHandle(chainId: chainId) else {
            return .unavailable(reason: "node not running for chain \(chainId)")
        }
        let json = await Task.detached(priority: .userInitiated) {
            from.withCString { fromPtr in
                to.withCString { toPtr in
                    data.withCString { dataPtr in
                        value.withCString { valuePtr in
                            Self.takeString(myotis_estimate_gas_json(
                                handle, fromPtr, toPtr, dataPtr, valuePtr
                            ))
                        }
                    }
                }
            }
        }.value
        guard let json else { return .unavailable(reason: "engine returned NULL") }
        return MyotisGasOutcome.decode(json)
    }

    /// Gossip a signed raw transaction over devp2p — no RPC provider in
    /// the loop.
    public func sendRawTransaction(chainId: UInt64, rawHex: String) async -> MyotisBroadcastOutcome {
        guard let handle = runningHandle(chainId: chainId) else {
            return .failed(message: "node not running for chain \(chainId)")
        }
        let json = await Task.detached(priority: .userInitiated) {
            rawHex.withCString { Self.takeString(myotis_send_raw_transaction_json(handle, $0)) }
        }.value
        guard let json else { return .failed(message: "engine returned NULL") }
        return MyotisBroadcastOutcome.decode(json)
    }

    /// Verified `eth_getTransactionByHash`: tx JSON, the literal "null"
    /// (verified not-seen — the correct "still pending" answer), or
    /// `{"error"}`. Returned as the raw JSON fragment.
    public func transactionByHash(chainId: UInt64, hash: String) async -> String? {
        guard let handle = runningHandle(chainId: chainId) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            hash.withCString { Self.takeString(myotis_get_transaction_by_hash_json(handle, $0)) }
        }.value
    }

    /// Verified block by tag ("latest" for the fee oracle's baseFee read).
    /// Returns the raw block JSON, "null", or `{"error"}`.
    public func blockByNumber(chainId: UInt64, tag: String, fullTransactions: Bool) async -> String? {
        guard let handle = runningHandle(chainId: chainId) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            tag.withCString {
                Self.takeString(myotis_get_block_by_number_json(handle, $0, fullTransactions))
            }
        }.value
    }

    /// Verified EL head as a hex quantity for `eth_blockNumber`, nil when
    /// the chain isn't serving.
    public func blockNumberHex(chainId: UInt64) -> String? {
        guard let status = chainStatus[chainId], status.ready, status.executionBlockNumber > 0 else {
            return nil
        }
        return "0x" + String(status.executionBlockNumber, radix: 16)
    }
}
