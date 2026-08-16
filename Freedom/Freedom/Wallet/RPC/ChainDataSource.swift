import Foundation
import BigInt
import Colibri
import MyotisKit
import OSLog

private let log = Logger(subsystem: "com.browser.Freedom", category: "ChainData")

/// A verified chain-data source that can answer some JSON-RPC methods for
/// some chains, ahead of the direct RPC pool. Mirrors desktop
/// freedom-browser's chain-data-router sources (PR #181): sources are
/// walked in order; a `ChainSourceUnavailable` throw means "can't serve
/// this one, fall through", while a `WalletRPC.Error` throw is a
/// deterministic protocol answer (verified revert, invalid params) that
/// short-circuits the ladder.
@MainActor
protocol ChainDataSource: AnyObject {
    /// For logs.
    var sourceName: String { get }
    /// Whether the source can plausibly answer for this chain right now.
    /// False skips it without burning an attempt.
    func isAvailable(chainID: Int) -> Bool
    /// Whether the source serves this exact `(method, params)` shape.
    /// Params-aware on purpose: a non-`latest` block tag, state
    /// overrides, or extra call-object fields must route to a source
    /// that honours them — never be answered "verified" without them.
    func serves(method: String, params: [Any], chainID: Int) -> Bool
    /// The JSON-RPC `result` value (`NSNull` for a well-defined null).
    func result(method: String, params: [Any], chainID: Int) async throws -> Any
}

/// "This source can't serve the request right now" — the ladder falls
/// through to the next source. Not an error the caller ever sees.
struct ChainSourceUnavailable: Error {
    let reason: String
}

// MARK: - Shared param gates (pure, unit-tested)

enum ChainCallShape {
    /// The only call-object fields the Myotis engine executes. Anything
    /// else (gas caps, fee fields, nonce, access lists) would be
    /// silently ignored — and the answer wrongly labeled verified — so
    /// their presence must fail the gate. Desktop parity.
    private static let servableCallFields: Set<String> = ["from", "to", "data", "input", "value"]

    /// True when `params[index]` is absent or the `latest` tag.
    static func isLatestTag(_ params: [Any], index: Int) -> Bool {
        guard params.count > index else { return true }
        guard let tag = params[index] as? String else { return false }
        return tag == "latest"
    }

    /// Strict gate for `eth_call` / `eth_estimateGas` against a verified
    /// head: latest-tag only, no state/block overrides (params[2+]), no
    /// unsupported call fields, no conflicting `data`/`input` aliases.
    static func servableCall(_ params: [Any]) -> Bool {
        guard let call = params.first as? [String: Any] else { return false }
        guard isLatestTag(params, index: 1), params.count <= 2 else { return false }
        for (key, value) in call {
            guard servableCallFields.contains(key) else {
                // Empty strings/nulls don't constrain execution.
                if value is NSNull { continue }
                if let s = value as? String, s.isEmpty { continue }
                return false
            }
        }
        let data = normalizedHex(call["data"])
        let input = normalizedHex(call["input"])
        if let data, let input, data != input { return false }
        return call["to"] is String
    }

    /// Canonical calldata from a call object (`input` is the standard
    /// alias, `data` the legacy one).
    static func calldata(_ call: [String: Any]) -> String {
        normalizedHex(call["data"]) ?? normalizedHex(call["input"]) ?? "0x"
    }

    private static func normalizedHex(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        return (t.isEmpty || t == "0x") ? nil : t
    }

    /// Hex QUANTITY (or decimal) → decimal wei string for the engine.
    static func decimalWei(_ value: Any?) -> String {
        guard let s = value as? String, !s.isEmpty else {
            if let n = value as? NSNumber { return n.stringValue }
            return "0"
        }
        if s.lowercased().hasPrefix("0x") {
            return (BigUInt(s.dropFirst(2), radix: 16) ?? 0).description
        }
        return BigUInt(s).map(\.description) ?? "0"
    }

    /// Decimal string → 0x-hex QUANTITY for JSON-RPC results.
    static func hexQuantity(decimal: String) -> String {
        "0x" + (BigUInt(decimal) ?? 0).serialize().hexQuantityDigits
    }

    static func hexQuantity(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16)
    }
}

private extension Data {
    /// Minimal hex digits for a QUANTITY (no leading zeros, "0" for zero).
    var hexQuantityDigits: String {
        let hex = map { String(format: "%02x", $0) }.joined().drop { $0 == "0" }
        return hex.isEmpty ? "0" : String(hex)
    }
}

// MARK: - Myotis source

/// Fully-P2P verified reads (and devp2p broadcast) from the embedded
/// light client. Serves mainnet + Gnosis only, `latest`-tag reads only.
@MainActor
final class MyotisChainSource: ChainDataSource {
    let sourceName = "myotis"
    private let node: MyotisNode

    init(node: MyotisNode) {
        self.node = node
    }

    func isAvailable(chainID: Int) -> Bool {
        chainID >= 0 && node.isReady(chainId: UInt64(chainID))
    }

    func serves(method: String, params: [Any], chainID: Int) -> Bool {
        guard MyotisNetwork.allCases.contains(where: { $0.chainId == UInt64(chainID) }) else {
            return false
        }
        switch method {
        case "eth_getBalance", "eth_getTransactionCount":
            // The wallet's nonce reads use the "pending" tag — those fall
            // through here by design (the engine serves mined state).
            return params.first is String && ChainCallShape.isLatestTag(params, index: 1)
        case "eth_call", "eth_estimateGas":
            return ChainCallShape.servableCall(params)
        case "eth_gasPrice", "eth_blockNumber", "eth_sendRawTransaction":
            return true
        case "eth_getTransactionByHash":
            return params.first is String
        case "eth_getBlockByNumber":
            // The fee oracle's baseFee read: latest header, hashes only.
            guard let tag = params.first as? String, tag == "latest" else { return false }
            let full = params.count > 1 ? (params[1] as? Bool ?? true) : true
            return full == false
        default:
            return false
        }
    }

    func result(method: String, params: [Any], chainID: Int) async throws -> Any {
        let chainId = UInt64(chainID)
        switch method {
        case "eth_getBalance", "eth_getTransactionCount":
            let outcome = await node.requestAccount(chainId: chainId, address: params[0] as? String ?? "")
            guard case .ok(let balanceWei, let nonce) = outcome else {
                throw unavailable(outcome)
            }
            return method == "eth_getBalance"
                ? ChainCallShape.hexQuantity(decimal: balanceWei)
                : ChainCallShape.hexQuantity(nonce)

        case "eth_call":
            let call = params[0] as? [String: Any] ?? [:]
            let outcome = await node.ethCall(
                chainId: chainId,
                from: call["from"] as? String ?? "",
                to: call["to"] as? String ?? "",
                data: ChainCallShape.calldata(call),
                value: ChainCallShape.decimalWei(call["value"]),
                block: "latest"
            )
            switch outcome {
            case .ok(let resultHex):
                return resultHex
            case .revert(let dataHex):
                // Verified chain answer — standard `execution reverted`
                // (code 3). Short-circuits the ladder.
                throw WalletRPC.Error.rpc(code: 3, message: "execution reverted \(dataHex)")
            case .unavailable(let reason), .error(let reason):
                throw ChainSourceUnavailable(reason: reason)
            }

        case "eth_estimateGas":
            let call = params[0] as? [String: Any] ?? [:]
            let outcome = await node.estimateGas(
                chainId: chainId,
                from: call["from"] as? String ?? "",
                to: call["to"] as? String ?? "",
                data: ChainCallShape.calldata(call),
                value: ChainCallShape.decimalWei(call["value"])
            )
            switch outcome {
            case .ok(let gas):
                return ChainCallShape.hexQuantity(gas)
            case .revert(let dataHex):
                throw WalletRPC.Error.rpc(code: 3, message: "execution reverted \(dataHex)")
            case .unavailable(let reason):
                throw ChainSourceUnavailable(reason: reason)
            }

        case "eth_gasPrice":
            let outcome = await node.feeEstimate(chainId: chainId)
            guard case .ok(let gasPriceWei, _) = outcome else {
                throw unavailable(outcome)
            }
            return ChainCallShape.hexQuantity(decimal: gasPriceWei)

        case "eth_blockNumber":
            guard let hex = node.blockNumberHex(chainId: chainId) else {
                throw ChainSourceUnavailable(reason: "no verified head")
            }
            return hex

        case "eth_sendRawTransaction":
            let outcome = await node.sendRawTransaction(
                chainId: chainId, rawHex: params.first as? String ?? ""
            )
            switch outcome {
            case .ok(let txHash):
                log.info("[chain-data] broadcast via myotis devp2p tx=\(txHash, privacy: .public)")
                return txHash
            case .failed(let message):
                throw ChainSourceUnavailable(reason: message)
            }

        case "eth_getTransactionByHash":
            guard let json = await node.transactionByHash(
                chainId: chainId, hash: params.first as? String ?? ""
            ) else {
                throw ChainSourceUnavailable(reason: "engine returned NULL")
            }
            return try Self.jsonFragment(json)

        case "eth_getBlockByNumber":
            guard let json = await node.blockByNumber(
                chainId: chainId, tag: "latest", fullTransactions: false
            ) else {
                throw ChainSourceUnavailable(reason: "engine returned NULL")
            }
            return try Self.jsonFragment(json)

        default:
            throw ChainSourceUnavailable(reason: "unsupported method \(method)")
        }
    }

    /// Parse an engine JSON fragment: `"null"` → NSNull (a verified
    /// absence), `{"error"}` → unavailable, else the decoded value.
    private static func jsonFragment(_ json: String) throws -> Any {
        if json == "null" { return NSNull() }
        guard let value = try? JSONSerialization.jsonObject(
            with: Data(json.utf8), options: [.fragmentsAllowed]
        ) else {
            throw ChainSourceUnavailable(reason: "undecodable engine response")
        }
        if let obj = value as? [String: Any], let error = obj["error"] as? String {
            throw ChainSourceUnavailable(reason: error)
        }
        return value
    }

    private func unavailable(_ outcome: MyotisAccountOutcome) -> ChainSourceUnavailable {
        if case .unavailable(let reason) = outcome { return ChainSourceUnavailable(reason: reason) }
        return ChainSourceUnavailable(reason: "unexpected outcome")
    }

    private func unavailable(_ outcome: MyotisFeeOutcome) -> ChainSourceUnavailable {
        if case .unavailable(let reason) = outcome { return ChainSourceUnavailable(reason: reason) }
        return ChainSourceUnavailable(reason: "unexpected outcome")
    }
}

// MARK: - Colibri source

/// Prover-backed verified reads for chains Colibri supports (mainnet +
/// Gnosis since 2.0.x). One `Colibri()` instance per chain, rebuilt when
/// the prover settings change — same lifecycle as `ColibriENSClient`.
@MainActor
final class ColibriChainSource: ChainDataSource {
    let sourceName = "colibri"
    private static let supportedChains: Set<Int> = [1, 100]
    private static let servableMethods: Set<String> = ["eth_call", "eth_getBalance"]

    private let settings: SettingsStore
    private let chainStore: ChainStore
    private var cached: [Int: Colibri] = [:]
    private var cachedKey: String?

    init(settings: SettingsStore, chainStore: ChainStore) {
        self.settings = settings
        self.chainStore = chainStore
    }

    func isAvailable(chainID: Int) -> Bool {
        Self.supportedChains.contains(chainID)
    }

    func serves(method: String, params: [Any], chainID: Int) -> Bool {
        guard Self.supportedChains.contains(chainID),
              Self.servableMethods.contains(method) else { return false }
        switch method {
        case "eth_getBalance":
            return params.first is String && ChainCallShape.isLatestTag(params, index: 1)
        case "eth_call":
            return ChainCallShape.servableCall(params)
        default:
            return false
        }
    }

    func result(method: String, params: [Any], chainID: Int) async throws -> Any {
        let client = currentClient(chainID: chainID)
        let paramsJSON = try JSONSerialization.data(withJSONObject: params)
        let paramsString = String(data: paramsJSON, encoding: .utf8) ?? "[]"
        do {
            return try await client.rpc(method: method, params: paramsString)
        } catch {
            if case let ColibriError.revert(data) = error {
                throw WalletRPC.Error.rpc(code: 3, message: "execution reverted \(data)")
            }
            throw ChainSourceUnavailable(reason: String(describing: error))
        }
    }

    /// Mirror of `ColibriENSClient.currentClient`, parameterized by
    /// chain: mainnet honours the user's prover override, Gnosis uses
    /// the binding's per-chain prover defaults.
    private func currentClient(chainID: Int) -> Colibri {
        let key = "\(resolvedMainnetProver)|\(settings.ensColibriZkProof)"
        if cachedKey != key { cached.removeAll(); cachedKey = key }
        if let client = cached[chainID] { return client }
        let client = Colibri()
        client.chainId = UInt64(chainID)
        client.provers = chainID == 1
            ? [resolvedMainnetProver]
            : Colibri.defaultProvers(for: UInt64(chainID))
        client.zkProof = settings.ensColibriZkProof
        client.privacyMode = .basic
        client.maxLatestAgeSeconds = 60
        client.eth_rpcs = chainStore.rpcURLs(forChainID: chainID)
        cached[chainID] = client
        return client
    }

    private var resolvedMainnetProver: String {
        let raw = settings.ensColibriProverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? ColibriENSClient.defaultProverURL : raw
    }
}
