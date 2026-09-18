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

    /// A page-driven read gives a source this long before falling
    /// through, when a later source exists (desktop
    /// `INTERACTIVE_SOURCE_DEADLINE_MS`). Tests shorten it.
    var interactiveDeadline: TimeInterval = 2

    private let registry: ChainRegistry
    private let transport: Transport
    let adaptive: AdaptiveRouting
    let admission: SourceAdmission

    init(
        registry: ChainRegistry,
        transport: @escaping Transport = ChainDataRouter.defaultTransport,
        clock: @escaping () -> Date = Date.init
    ) {
        self.registry = registry
        self.transport = transport
        self.adaptive = AdaptiveRouting(clock: clock)
        self.admission = SourceAdmission()
    }

    /// The two-second budget is a *fall-through* allowance, not a global
    /// ceiling: it only pays off when a later source can still answer
    /// and a page the user is watching is waiting. Applied blindly it
    /// would downgrade a verified wallet read on a slow network to an
    /// unverified one, and on the last configured source it would turn
    /// a read that would have succeeded into a failure.
    func sourceWait(policy: ChainAccessPolicy, interactive: Bool, hasFallback: Bool) -> TimeInterval {
        interactive && hasFallback ? min(policy.sourceTimeout, interactiveDeadline) : policy.sourceTimeout
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

        let order = policy.readOrder
        for (index, source) in order.enumerated() {
            if directOnly && source != .direct { continue }
            try Task.checkCancellation()
            let routeKey = source == .direct ? nil
                : AdaptiveRouting.routeKey(source: source, chainID: chainID, method: method, params: params, context: context)
            if adaptive.isBypassed(routeKey) {
                log.info(
                    "[chain-data] \(method, privacy: .public) chain=\(chainID) \(source.rawValue, privacy: .public) bypassed for this app workload: \(self.adaptive.bypassReason(routeKey) ?? "", privacy: .public)"
                )
                sourceFailures.append(ChainSourceUnavailable(reason: "\(source.rawValue) temporarily bypassed for this app workload"))
                continue
            }
            let wait = sourceWait(policy: policy, interactive: context.isInteractive, hasFallback: index + 1 < order.count)
            let started = ContinuousClock.now
            do {
                let answer: ChainDataResult
                switch source {
                case .myotis, .colibri:
                    answer = try await requestVerifiedSource(
                        source, chainID: chainID, method: method, params: params,
                        options: options, policy: policy, routeKey: routeKey, wait: wait
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
                adaptive.recordSuccess(routeKey)
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
                Self.logFailure(method: method, chainID: chainID, source: source, error: error, elapsed: started.duration(to: .now))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                adaptive.recordFailure(routeKey, kind: Self.failureKind(error))
                sourceFailures.append(error)
                Self.logFailure(method: method, chainID: chainID, source: source, error: error, elapsed: started.duration(to: .now))
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
        options: Options,
        policy: ChainAccessPolicy,
        routeKey: String?,
        wait: TimeInterval
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
        switch kind {
        case .myotis:
            return try await requestViaMyotis(source, chainID: chainID, method: method, params: params, options: options, budget: wait)
        default:
            let inFlightKey = routeKey ?? [
                kind.rawValue, String(chainID), method, AdaptiveRouting.requestTarget(method: method, params: params),
            ].joined(separator: "\u{1F}")
            return try await requestViaColibri(source, chainID: chainID, method: method, params: params, options: options, routeKey: inFlightKey, wait: wait)
        }
    }

    /// One read at a time per chain, a bounded queue behind it. One
    /// budget covers the queue wait *and* the read, so serializing never
    /// costs a caller more than a solo read would. The slot is held
    /// until the engine settles — a deadline limits the caller's
    /// patience, not native health; fallbacks answer meanwhile.
    private func requestViaMyotis(
        _ source: ChainDataSource,
        chainID: Int,
        method: String,
        params: [Any],
        options: Options,
        budget: TimeInterval
    ) async throws -> ChainDataResult {
        guard let slot = admission.acquireMyotis(chainID: chainID) else {
            throw ChainSourceUnavailable(reason: "Myotis has too many reads queued for this workload")
        }
        let started = ContinuousClock.now
        if case .queued(let waiter) = slot {
            do {
                try await withSourceDeadline(budget, source: .myotis) { await waiter.wait() }
            } catch {
                admission.abandonMyotis(chainID: chainID, waiter: waiter)
                throw error
            }
        }
        let admission = self.admission
        let work = Task { @MainActor () throws -> ChainDataResult in
            defer { admission.releaseMyotis(chainID: chainID) }
            return try await self.execute(source, kind: .myotis, chainID: chainID, method: method, params: params, options: options)
        }
        let elapsed = TimeInterval(started.duration(to: .now).components.seconds)
            + TimeInterval(started.duration(to: .now).components.attoseconds) / 1e18
        return try await withSourceDeadline(max(0.001, budget - elapsed), source: .myotis) { try await work.value }
    }

    /// A global and a per-route cap on prover work in flight; beyond
    /// them the caller falls through instead of parking more. A prover
    /// call cannot be cancelled, so it stays tracked until it settles
    /// and its wait is never unbounded.
    private func requestViaColibri(
        _ source: ChainDataSource,
        chainID: Int,
        method: String,
        params: [Any],
        options: Options,
        routeKey: String,
        wait: TimeInterval
    ) async throws -> ChainDataResult {
        guard admission.admitColibri(routeKey: routeKey) else {
            throw ChainSourceUnavailable(reason: "Colibri is already processing this workload")
        }
        let admission = self.admission
        let work = Task { @MainActor () throws -> ChainDataResult in
            defer { admission.releaseColibri(routeKey: routeKey) }
            return try await self.execute(source, kind: .colibri, chainID: chainID, method: method, params: params, options: options)
        }
        return try await withSourceDeadline(wait, source: .colibri) { try await work.value }
    }

    /// The call itself, with the source's evidence attached.
    private func execute(
        _ source: ChainDataSource,
        kind: ChainSource,
        chainID: Int,
        method: String,
        params: [Any],
        options: Options
    ) async throws -> ChainDataResult {
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

    /// What the adaptive layer should remember about a failure, if
    /// anything. Desktop `failureKind`.
    static func failureKind(_ error: Swift.Error) -> ChainSourceFailureKind? {
        if error is ChainSourceDeadline { return .timeout }
        if let unavailable = error as? ChainSourceUnavailable {
            if let kind = unavailable.failureKind { return kind }
            return ChainSourceUnavailable.isCapacityMessage(unavailable.reason) ? .capacity : nil
        }
        if (error as? URLError)?.code == .timedOut { return .timeout }
        return ChainSourceUnavailable.isCapacityMessage(safeErrorMessage(error)) ? .capacity : nil
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

    private static func logFailure(method: String, chainID: Int, source: ChainSource, error: Swift.Error, elapsed: Duration) {
        let reason = (error as? ChainSourceUnavailable)?.reason ?? Self.safeErrorMessage(error)
        log.info(
            "[chain-data] \(method, privacy: .public) chain=\(chainID) \(source.rawValue, privacy: .public) failed after \(Self.millis(elapsed))ms: \(reason, privacy: .public) — falling through"
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
