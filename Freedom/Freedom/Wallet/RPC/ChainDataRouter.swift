import BigInt
import Foundation
import OSLog

private let log = Logger(subsystem: "com.browser.Freedom", category: "ChainData")

/// One router for every chain read on iOS — desktop's
/// `chain-data-router.js`. Walks the chain's configured source order
/// (Myotis → Colibri → RPC quorum → direct by default), skips tiers that
/// cannot serve the request's shape, and returns the first answer
/// together with *who answered* (`ChainDataResult.trust`). A
/// deterministic protocol answer from any tier — an execution revert
/// with data, `-32602`, insufficient funds — ends the walk; anything
/// else falls through to the next tier.
///
/// `WalletRPC` is the typed façade over `request`; the dapp bridge and
/// the onchain-app loader call it with the page's `RoutingContext`.
@MainActor
final class ChainDataRouter {
    /// Single-URL transport: pre-encoded JSON body in, raw response
    /// bytes out, bounded by the given timeout. Tests inject a stub.
    typealias Transport = @Sendable (URL, Data, TimeInterval) async throws -> Data

    /// Per-request knobs that are not part of the routing policy.
    struct Options: Sendable {
        /// Treat a JSON `null` result as a malformed answer (retry the
        /// next endpoint / tier) rather than a well-defined absence.
        /// `WalletRPC.call` sets it; `callOptional` does not.
        var rejectNull = false

        static let standard = Options()
    }

    /// Methods a verified tier can never serve (stateful filters, node
    /// identity). They skip straight to the direct tier.
    static let directOnlyMethods: Set<String> = [
        "eth_getFilterChanges", "eth_getFilterLogs", "eth_newFilter",
        "eth_newBlockFilter", "eth_newPendingTransactionFilter", "eth_uninstallFilter",
        "web3_clientVersion", "web3_sha3",
    ]

    /// `-32602 Invalid params` (EIP-1474): every well-behaved server
    /// rejects the same way, so iterating cannot help.
    static let invalidParamsCode = -32602

    nonisolated static let defaultTransport: Transport = { url, body, timeout in
        try await RPCSession.postBytes(url: url, body: body, timeout: timeout)
    }

    private let registry: ChainRegistry
    private let transport: Transport

    init(registry: ChainRegistry, transport: @escaping Transport = ChainDataRouter.defaultTransport) {
        self.registry = registry
        self.transport = transport
    }

    // MARK: - Reads

    /// Route one JSON-RPC read through the chain's policy.
    func request(
        chainID: Int,
        method: String,
        params rawParams: [Any],
        context: RoutingContext = .wallet,
        options: Options = .standard
    ) async throws -> ChainDataResult {
        let policy = registry.policy(forChainID: chainID)
        let params = ChainCallShape.normalizeParams(method: method, params: rawParams)
        let directOnly = Self.directOnlyMethods.contains(method)
        /// Verified tiers that were tried (or could not be) and fell
        /// through; reported only when no direct tier ran.
        var sourceFailures: [Swift.Error] = []
        /// The direct tier's per-endpoint errors — what `allProvidersFailed`
        /// has always carried.
        var directErrors: [Swift.Error] = []
        var sawEmptyPool = false

        for source in policy.readOrder {
            if directOnly && source != .direct { continue }
            try Task.checkCancellation()
            let started = ContinuousClock.now
            do {
                let answer: ChainDataResult
                switch source {
                case .myotis, .colibri:
                    answer = try await requestVerifiedSource(
                        source, chainID: chainID, method: method, params: params, options: options
                    )
                case .quorum:
                    // Phase 3 lands the M-of-K tier; until then the order
                    // walks past it silently.
                    continue
                case .direct:
                    answer = try await requestDirect(
                        chainID: chainID, method: method, params: params, policy: policy, options: options
                    )
                }
                let elapsed = started.duration(to: .now)
                log.info(
                    "[chain-data] \(method, privacy: .public) chain=\(chainID) via \(source.rawValue, privacy: .public) \(Self.millis(elapsed))ms"
                )
                return answer
            } catch let error as WalletRPC.Error {
                switch error {
                case .rpc, .insufficientFunds:
                    // Deterministic protocol answers end the walk.
                    throw error
                case .allProvidersFailed(let errors):
                    directErrors = errors
                case .noProviders:
                    sawEmptyPool = true
                case .invalidResponse:
                    directErrors.append(error)
                }
                Self.logFailure(method: method, chainID: chainID, source: source, error: error)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                sourceFailures.append(error)
                Self.logFailure(method: method, chainID: chainID, source: source, error: error)
            }
        }

        if !directErrors.isEmpty { throw WalletRPC.Error.allProvidersFailed(directErrors) }
        if sawEmptyPool { throw WalletRPC.Error.noProviders }
        throw WalletRPC.Error.allProvidersFailed(sourceFailures)
    }

    // MARK: - Verified sources (Myotis, Colibri)

    private func requestVerifiedSource(
        _ kind: ChainSource,
        chainID: Int,
        method: String,
        params: [Any],
        options: Options
    ) async throws -> ChainDataResult {
        guard let source = registry.source(kind) else {
            throw ChainSourceUnavailable(reason: "\(kind.rawValue) is not installed")
        }
        guard source.isAvailable(chainID: chainID) else {
            throw ChainSourceUnavailable(reason: "\(kind.rawValue) is not available for chain \(chainID)")
        }
        guard source.serves(method: method, params: params, chainID: chainID) else {
            throw ChainSourceUnavailable(reason: "\(kind.rawValue) cannot serve this \(method) shape")
        }
        let headBefore = source.verifiedHead(chainID: chainID)
        let result = try await source.result(method: method, params: params, chainID: chainID)
        if options.rejectNull, result is NSNull {
            throw ChainSourceUnavailable(reason: "\(kind.rawValue) returned null")
        }
        let headAfter = source.verifiedHead(chainID: chainID)
        // Label the answer with a block only when the verified head stayed
        // put around the call; a separately sampled newer head must never
        // be presented as the call's block (desktop `myotisTrust`).
        let block = (headBefore != nil && headBefore == headAfter) ? headAfter! : 0
        let label = source.evidenceLabel(chainID: chainID)
        let trust = ENSTrust(
            level: .verified,
            method: kind == .myotis ? .myotis : .colibri,
            block: ENSBlock(number: block, hash: ""),
            agreed: [label], dissented: [], queried: [label],
            k: 1, m: 1
        )
        return ChainDataResult(result: result, trust: trust, source: kind)
    }

    // MARK: - Direct tier

    /// The chain's pool walked in order (shuffled, quarantined ones
    /// skipped): next URL on transport / malformed failure, which
    /// quarantines; a JSON-RPC error envelope iterates without
    /// quarantining (the provider is transport-healthy); a deterministic
    /// answer throws. Every URL exhausted → `allProvidersFailed`.
    private func requestDirect(
        chainID: Int,
        method: String,
        params: [Any],
        policy: ChainAccessPolicy,
        options: Options
    ) async throws -> ChainDataResult {
        let urls = registry.rpcURLs(forChainID: chainID)
        guard !urls.isEmpty else { throw WalletRPC.Error.noProviders }
        let body = try Self.encodeRequest(method: method, params: params)
        var errors: [Swift.Error] = []
        for url in urls {
            try Task.checkCancellation()
            let data: Data
            do {
                data = try await transport(url, body, policy.sourceTimeout)
            } catch {
                // Cancellation isn't a provider fault — rethrow without
                // touching quarantine.
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw error
                }
                registry.markFailure(url: url, chainID: chainID)
                errors.append(error)
                continue
            }
            switch Self.parseEnvelope(data, rejectNull: options.rejectNull) {
            case .success(let value):
                registry.markSuccess(url: url, chainID: chainID)
                return ChainDataResult(
                    result: value,
                    trust: Self.directTrust(endpoint: url, userConfigured: false),
                    source: .direct
                )
            case .rpcError(let code, let message, let hasRevertData):
                if Self.isInsufficientFunds(message: message) {
                    throw WalletRPC.Error.insufficientFunds(message: message)
                }
                if hasRevertData || code == Self.invalidParamsCode {
                    throw WalletRPC.Error.rpc(code: code, message: message)
                }
                // Don't mark — the provider responded correctly per spec.
                errors.append(WalletRPC.Error.rpc(code: code, message: message))
            case .malformed(let error):
                registry.markFailure(url: url, chainID: chainID)
                errors.append(error)
            }
        }
        throw WalletRPC.Error.allProvidersFailed(errors)
    }

    static func directTrust(endpoint: URL, userConfigured: Bool) -> ENSTrust {
        let host = endpoint.hostOrAbsolute
        return ENSTrust(
            level: userConfigured ? .userConfigured : .unverified,
            method: .direct,
            block: ENSBlock(number: 0, hash: ""),
            agreed: [host], dissented: [], queried: [host],
            k: 1, m: 1
        )
    }

    // MARK: - JSON-RPC envelope

    enum Envelope {
        case success(Any)
        /// `hasRevertData` flags an EIP-474 execution revert (`error.data`
        /// populated). Deterministic protocol answer → short-circuit.
        case rpcError(code: Int, message: String, hasRevertData: Bool)
        case malformed(Swift.Error)
    }

    static func encodeRequest(method: String, params: [Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": method, "params": params,
        ])
    }

    static func parseEnvelope(_ data: Data, rejectNull: Bool) -> Envelope {
        guard let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .malformed(WalletRPC.Error.invalidResponse)
        }
        if let errObj = envelope["error"] as? [String: Any] {
            let code = errObj["code"] as? Int ?? 0
            let message = errObj["message"] as? String ?? "unknown error"
            let hasRevertData = errObj["data"] is String
            return .rpcError(code: code, message: message, hasRevertData: hasRevertData)
        }
        guard let result = envelope["result"] else {
            return .malformed(WalletRPC.Error.invalidResponse)
        }
        if rejectNull, result is NSNull {
            return .malformed(WalletRPC.Error.invalidResponse)
        }
        return .success(result)
    }

    /// Substring match is fragile across exotic clients but covers the
    /// common public-RPC universe (geth/erigon/anvil all carry
    /// "insufficient funds" in the message).
    static func isInsufficientFunds(message: String) -> Bool {
        message.lowercased().contains("insufficient funds")
    }

    // MARK: - Logging

    private static func logFailure(method: String, chainID: Int, source: ChainSource, error: Swift.Error) {
        let reason = (error as? ChainSourceUnavailable)?.reason ?? Self.safeErrorMessage(error)
        log.info(
            "[chain-data] \(method, privacy: .public) chain=\(chainID) \(source.rawValue, privacy: .public) failed: \(reason, privacy: .public) — falling through"
        )
    }

    /// Desktop's `safeErrorMessage`: long hex blobs elided, whitespace
    /// collapsed, capped so a revert payload cannot flood the log.
    static func safeErrorMessage(_ error: Swift.Error) -> String {
        let raw = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        var out = raw.replacingOccurrences(
            of: #"0x[0-9a-fA-F]{128,}"#,
            with: "0x…(hex)",
            options: .regularExpression
        )
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return String(out.prefix(500))
    }

    private static func millis(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1_000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}

// MARK: - Param normalization

extension ChainCallShape {
    /// Numeric fields of a JSON-RPC call object are QUANTITYs and must
    /// travel as hex; the `input` alias is canonicalised into `data`.
    /// Applied once, at the boundary every tier shares, so every source
    /// (and every quorum member) sees the same bytes. Desktop parity
    /// (`normalizeParams`).
    static let callObjectMethods: Set<String> = ["eth_call", "eth_estimateGas"]
    static let callQuantityFields = ["value", "gas", "gasPrice", "maxFeePerGas", "maxPriorityFeePerGas", "nonce"]

    static func normalizeParams(method: String, params: [Any]) -> [Any] {
        guard callObjectMethods.contains(method), let call = params.first as? [String: Any] else {
            return params
        }
        var normalized = call
        if let input = nonEmptyHex(call["input"]), nonEmptyHex(call["data"]) == nil {
            normalized["data"] = call["input"]
        }
        for field in callQuantityFields {
            guard let value = call[field], let hex = quantityHex(value), (value as? String) != hex else { continue }
            normalized[field] = hex
        }
        var out = params
        out[0] = normalized
        return out
    }

    /// `0x…` hex (re-minimised), a decimal string or a number → hex
    /// QUANTITY. Nil for anything else (left for the node to reject).
    static func quantityHex(_ value: Any) -> String? {
        if let n = value as? NSNumber {
            // JSON booleans surface as NSNumber too; they are not quantities.
            guard CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue >= 0,
                  n.doubleValue == n.doubleValue.rounded() else { return nil }
            return "0x" + String(n.uint64Value, radix: 16)
        }
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("0x") {
            guard let big = BigUInt(trimmed.dropFirst(2), radix: 16) else { return nil }
            return "0x" + String(big, radix: 16)
        }
        guard let big = BigUInt(trimmed) else { return nil }
        return "0x" + String(big, radix: 16)
    }

    private static func nonEmptyHex(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        return (t.isEmpty || t == "0x") ? nil : t
    }
}
