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
        /// Skip every verified tier (DEBUG smoke hook for the onchain
        /// loader's unverified path). Never set from user-facing code.
        var directOnly = false

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

    let registry: ChainRegistry
    let transport: Transport
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

    /// Route one JSON-RPC read through the chain's policy. Throws only
    /// `WalletRPC.Error` (deterministic answers, exhausted tiers) or
    /// `CancellationError`; a tier's own failure never reaches a caller.
    func request(
        chainID: Int,
        method: String,
        params rawParams: [Any],
        context: RoutingContext = .wallet,
        options: Options = .standard
    ) async throws -> ChainDataResult {
        do {
            return try await walk(chainID: chainID, method: method, params: rawParams, context: context, options: options)
        } catch let error as WalletRPC.Error {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WalletRPC.Error.allProvidersFailed([error])
        }
    }

    private func walk(
        chainID: Int,
        method: String,
        params rawParams: [Any],
        context: RoutingContext,
        options: Options
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
        /// A quorum member's answer the direct tier can reuse, and the
        /// endpoints the quorum already asked.
        var directFallback: DirectFallback?
        var directAttempted: [URL] = []

        let order = policy.readOrder
        for (index, source) in order.enumerated() {
            if (directOnly || options.directOnly) && source != .direct { continue }
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
                    let next = index + 1 < order.count ? order[index + 1] : nil
                    let outcome = await requestQuorum(
                        chainID: chainID, method: method, params: params, policy: policy, options: options,
                        wait: wait, allowDirectFallback: next == .direct
                    )
                    switch outcome {
                    case .agreed(.value(let value), let trust):
                        answer = ChainDataResult(result: value, trust: trust, source: .quorum)
                    case .agreed(.deterministic(let error), _):
                        // M members agree on the revert: a verified
                        // deterministic answer, which ends the walk.
                        throw error
                    case .failed(let reason, let kind, let fallback, let attempted, let errors):
                        directFallback = fallback
                        directAttempted = attempted
                        directErrors = errors
                        throw ChainSourceUnavailable(reason: reason, kind: kind)
                    }
                case .direct:
                    answer = try await requestDirect(
                        chainID: chainID, method: method, params: params, policy: policy, options: options,
                        fallback: directFallback, attempted: directAttempted, priorErrors: directErrors
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
                case .rpc, .insufficientFunds, .broadcastUncertain:
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

    // MARK: - Broadcast

    /// Which tier accepted a signed transaction.
    struct BroadcastReceipt {
        let hash: String
        let source: ChainSource
    }

    /// Walk `policy.broadcastOrder`. An uncertain Myotis outcome is
    /// terminal — the transaction may already be propagating over
    /// devp2p, so it is never re-broadcast elsewhere; the wallet must
    /// reconcile the original signed transaction. A direct node
    /// rejection keeps its JSON-RPC code.
    func broadcast(chainID: Int, rawTransaction: String) async throws -> BroadcastReceipt {
        let policy = registry.policy(forChainID: chainID)
        let method = "eth_sendRawTransaction"
        let params: [Any] = [rawTransaction]
        var sourceFailures: [Swift.Error] = []
        var directErrors: [Swift.Error] = []
        var sawEmptyPool = false
        for source in policy.broadcastOrder {
            try Task.checkCancellation()
            do {
                switch source {
                case .myotis:
                    guard let myotis = registry.source(.myotis),
                          myotis.isAvailable(chainID: chainID),
                          myotis.serves(method: method, params: params, chainID: chainID) else {
                        throw ChainSourceUnavailable(reason: "myotis is not ready")
                    }
                    let hash: String
                    do {
                        guard let value = try await myotis.result(method: method, params: params, chainID: chainID) as? String else {
                            throw WalletRPC.Error.broadcastUncertain(message: "unexpected engine response")
                        }
                        hash = value
                    } catch let error as WalletRPC.Error {
                        throw error
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        let reason = (error as? ChainSourceUnavailable)?.reason ?? Self.safeErrorMessage(error)
                        throw WalletRPC.Error.broadcastUncertain(message: reason)
                    }
                    log.info("[chain-data] broadcast chain=\(chainID) via myotis tx=\(hash, privacy: .public)")
                    return BroadcastReceipt(hash: hash, source: .myotis)
                case .direct:
                    let answer = try await requestDirect(
                        chainID: chainID, method: method, params: params, policy: policy, options: .init(rejectNull: true)
                    )
                    guard let hash = answer.result as? String else { throw WalletRPC.Error.invalidResponse }
                    log.info("[chain-data] broadcast chain=\(chainID) via direct \(answer.trust.agreed.first ?? "", privacy: .public) tx=\(hash, privacy: .public)")
                    return BroadcastReceipt(hash: hash, source: .direct)
                case .colibri, .quorum:
                    throw ChainSourceUnavailable(reason: "\(source.rawValue) cannot broadcast transactions")
                }
            } catch let error as WalletRPC.Error {
                switch error {
                case .rpc, .insufficientFunds, .broadcastUncertain:
                    throw error
                case .allProvidersFailed(let errors):
                    directErrors = errors
                case .noProviders:
                    sawEmptyPool = true
                case .invalidResponse:
                    directErrors.append(error)
                }
                Self.logFailure(method: method, chainID: chainID, source: source, error: error, elapsed: .zero)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                sourceFailures.append(error)
                Self.logFailure(method: method, chainID: chainID, source: source, error: error, elapsed: .zero)
            }
        }
        if !directErrors.isEmpty { throw WalletRPC.Error.allProvidersFailed(directErrors) }
        if sawEmptyPool { throw WalletRPC.Error.noProviders }
        throw WalletRPC.Error.allProvidersFailed(sourceFailures)
    }

    // MARK: - Fee quote

    /// A gas price and the block it should be sanity-checked against,
    /// from one source. Falling through the ladder independently for
    /// each component is what produced mixed, invalid quotes on desktop;
    /// here both come from the same tier — and on direct, the same URL.
    struct FeeQuote {
        /// Hex wei.
        let gasPriceHex: String
        /// Latest block's `baseFeePerGas`, hex wei; nil when the source
        /// could not provide the header or the chain has no base fee.
        let baseFeePerGasHex: String?
        let source: ChainSource
        let trust: ENSTrust
    }

    /// The walk stops at the first tier that answers both `eth_gasPrice`
    /// and the latest header; a tier that can only give one of the two
    /// falls through, so the wallet's base-fee floor is never skipped.
    func feeQuote(chainID: Int) async throws -> FeeQuote {
        let policy = registry.policy(forChainID: chainID)
        let headerParams: [Any] = ["latest", false]
        var sourceFailures: [Swift.Error] = []
        var directErrors: [Swift.Error] = []
        var sawEmptyPool = false
        for (index, source) in policy.readOrder.enumerated() {
            try Task.checkCancellation()
            let wait = sourceWait(policy: policy, interactive: false, hasFallback: index + 1 < policy.readOrder.count)
            do {
                switch source {
                case .myotis, .colibri:
                    let price = try await requestVerifiedSource(
                        source, chainID: chainID, method: "eth_gasPrice", params: [],
                        options: .init(rejectNull: true), policy: policy, routeKey: nil, wait: wait
                    )
                    let header = try await requestVerifiedSource(
                        source, chainID: chainID, method: "eth_getBlockByNumber", params: headerParams,
                        options: .init(rejectNull: true), policy: policy, routeKey: nil, wait: wait
                    )
                    return try Self.feeQuote(price: price, header: header)
                case .quorum:
                    let priceOutcome = await requestQuorum(
                        chainID: chainID, method: "eth_gasPrice", params: [], policy: policy,
                        options: .init(rejectNull: true), wait: wait, allowDirectFallback: false
                    )
                    guard case .agreed(.value(let value), let trust) = priceOutcome else {
                        throw ChainSourceUnavailable(reason: "RPC quorum did not agree on a gas price")
                    }
                    guard case .agreed(.value(let block), let headerTrust) = await requestQuorum(
                        chainID: chainID, method: "eth_getBlockByNumber", params: headerParams, policy: policy,
                        options: .init(rejectNull: true), wait: wait, allowDirectFallback: false
                    ) else {
                        throw ChainSourceUnavailable(reason: "RPC quorum did not agree on the latest header")
                    }
                    return try Self.feeQuote(
                        price: ChainDataResult(result: value, trust: trust, source: .quorum),
                        header: ChainDataResult(result: block, trust: headerTrust, source: .quorum)
                    )
                case .direct:
                    return try await requestDirectFeeQuote(chainID: chainID, policy: policy)
                }
            } catch let error as WalletRPC.Error {
                switch error {
                case .rpc, .insufficientFunds, .broadcastUncertain:
                    throw error
                case .allProvidersFailed(let errors):
                    directErrors = errors
                case .noProviders:
                    sawEmptyPool = true
                case .invalidResponse:
                    directErrors.append(error)
                }
                Self.logFailure(method: "feeQuote", chainID: chainID, source: source, error: error, elapsed: .zero)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                sourceFailures.append(error)
                Self.logFailure(method: "feeQuote", chainID: chainID, source: source, error: error, elapsed: .zero)
            }
        }
        if !directErrors.isEmpty { throw WalletRPC.Error.allProvidersFailed(directErrors) }
        if sawEmptyPool { throw WalletRPC.Error.noProviders }
        throw WalletRPC.Error.allProvidersFailed(sourceFailures)
    }

    /// Both components from the same URL, deliberately.
    private func requestDirectFeeQuote(chainID: Int, policy: ChainAccessPolicy) async throws -> FeeQuote {
        let urls = registry.rpcURLs(forChainID: chainID)
        guard !urls.isEmpty else { throw WalletRPC.Error.noProviders }
        let priceBody = try Self.encodeRequest(method: "eth_gasPrice", params: [])
        let headerBody = try Self.encodeRequest(method: "eth_getBlockByNumber", params: ["latest", false])
        var errors: [Swift.Error] = []
        for url in urls {
            try Task.checkCancellation()
            switch await callEndpoint(url, body: priceBody, timeout: policy.sourceTimeout, chainID: chainID, rejectNull: true) {
            case .answer(.value(let price)):
                // Deliberately the same URL: an endpoint that quotes a
                // price but cannot serve its own head is skipped whole.
                guard case .answer(.value(let block)) = await callEndpoint(
                    url, body: headerBody, timeout: policy.sourceTimeout, chainID: chainID, rejectNull: true
                ) else {
                    errors.append(WalletRPC.Error.invalidResponse)
                    continue
                }
                let trust = Self.directTrust(endpoint: url, userConfigured: registry.isUserConfigured(url: url, chainID: chainID))
                log.info("[chain-data] feeQuote chain=\(chainID) via direct \(url.hostOrAbsolute, privacy: .public)")
                return try Self.feeQuote(
                    price: ChainDataResult(result: price, trust: trust, source: .direct),
                    header: ChainDataResult(result: block, trust: trust, source: .direct)
                )
            case .answer(.deterministic(let error)):
                throw error
            case .error(let error, _):
                if error is CancellationError { throw error }
                errors.append(error)
            }
        }
        throw WalletRPC.Error.allProvidersFailed(errors)
    }

    private static func feeQuote(price: ChainDataResult, header: ChainDataResult) throws -> FeeQuote {
        guard let gasPriceHex = price.result as? String, header.result is [String: Any] else {
            throw WalletRPC.Error.invalidResponse
        }
        let baseFee = (header.result as? [String: Any])?["baseFeePerGas"] as? String
        log.info("[chain-data] feeQuote chain via \(price.source.rawValue, privacy: .public) gasPrice=\(gasPriceHex, privacy: .public) baseFee=\(baseFee ?? "-", privacy: .public)")
        return FeeQuote(gasPriceHex: gasPriceHex, baseFeePerGasHex: baseFee, source: price.source, trust: price.trust)
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
    /// answer throws. Every URL exhausted → `allProvidersFailed`. A
    /// quorum member's answer is reused instead of a new request, and
    /// endpoints the quorum already asked are not asked again.
    private func requestDirect(
        chainID: Int,
        method: String,
        params: [Any],
        policy: ChainAccessPolicy,
        options: Options,
        fallback: DirectFallback? = nil,
        attempted: [URL] = [],
        priorErrors: [Swift.Error] = []
    ) async throws -> ChainDataResult {
        let urls = registry.rpcURLs(forChainID: chainID)
        guard !urls.isEmpty else { throw WalletRPC.Error.noProviders }
        if let fallback, urls.contains(fallback.url) {
            switch fallback.answer {
            case .deterministic(let error):
                throw error
            case .value(let value):
                let trust = ENSTrust(
                    level: registry.isUserConfigured(url: fallback.url, chainID: chainID) ? .userConfigured : .unverified,
                    method: .direct,
                    block: ENSBlock(number: 0, hash: ""),
                    agreed: fallback.agreedURLs.map(\.hostOrAbsolute),
                    dissented: fallback.dissentedURLs.map(\.hostOrAbsolute),
                    queried: fallback.queriedURLs.map(\.hostOrAbsolute),
                    k: fallback.k, m: fallback.m
                )
                log.info("[chain-data] \(method, privacy: .public) chain=\(chainID) direct reuses quorum member \(fallback.url.hostOrAbsolute, privacy: .public)")
                return ChainDataResult(result: value, trust: trust, source: .direct)
            }
        }
        let body = try Self.encodeRequest(method: method, params: params)
        let skip = Set(attempted)
        var errors: [Swift.Error] = []
        for url in urls where !skip.contains(url) {
            try Task.checkCancellation()
            switch await callEndpoint(url, body: body, timeout: policy.sourceTimeout, chainID: chainID, rejectNull: options.rejectNull) {
            case .answer(.value(let value)):
                return ChainDataResult(
                    result: value,
                    trust: Self.directTrust(endpoint: url, userConfigured: registry.isUserConfigured(url: url, chainID: chainID)),
                    source: .direct
                )
            case .answer(.deterministic(let error)):
                throw error
            case .error(let error, _):
                if error is CancellationError { throw error }
                errors.append(error)
            }
        }
        throw WalletRPC.Error.allProvidersFailed(errors.isEmpty ? priorErrors : errors)
    }

    /// One endpoint, one request: transport and malformed failures
    /// quarantine the URL, a JSON-RPC error envelope does not, a
    /// deterministic error is an answer. Shared by the direct tier and
    /// every quorum leg.
    func callEndpoint(
        _ url: URL, body: Data, timeout: TimeInterval, chainID: Int, rejectNull: Bool
    ) async -> QuorumLegResult {
        let data: Data
        do {
            data = try await transport(url, body, timeout)
        } catch {
            // Cancellation isn't a provider fault — report without
            // touching quarantine.
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return .error(CancellationError(), kind: nil)
            }
            registry.markFailure(url: url, chainID: chainID)
            return .error(error, kind: (error as? URLError)?.code == .timedOut ? .timeout : nil)
        }
        switch Self.parseEnvelope(data, rejectNull: rejectNull) {
        case .success(let value):
            registry.markSuccess(url: url, chainID: chainID)
            return .answer(.value(value))
        case .rpcError(let code, let message, let hasRevertData):
            if Self.isInsufficientFunds(message: message) {
                return .answer(.deterministic(.insufficientFunds(message: message)))
            }
            if hasRevertData || code == Self.invalidParamsCode {
                return .answer(.deterministic(.rpc(code: code, message: message)))
            }
            // Don't mark — the provider responded correctly per spec.
            let kind: ChainSourceFailureKind? = ChainSourceUnavailable.isCapacityMessage(message) ? .capacity : nil
            return .error(WalletRPC.Error.rpc(code: code, message: message), kind: kind)
        case .malformed(let error):
            registry.markFailure(url: url, chainID: chainID)
            return .error(error, kind: nil)
        }
    }

    // MARK: - Quorum tier

    /// K endpoints of the pool asked concurrently with the same bytes.
    /// `wait` caps verification (the interactive budget when a source
    /// follows); each leg keeps the configured endpoint timeout when a
    /// direct tier follows so a late single answer can still serve it.
    private func requestQuorum(
        chainID: Int,
        method: String,
        params: [Any],
        policy: ChainAccessPolicy,
        options: Options,
        wait: TimeInterval,
        allowDirectFallback: Bool
    ) async -> QuorumOutcome {
        let k = policy.effectiveQuorumK
        let m = policy.effectiveQuorumM
        let timeout = min(policy.sourceTimeout, wait)
        let endpointTimeout = allowDirectFallback ? policy.sourceTimeout : timeout
        let urls = Array(registry.rpcURLs(forChainID: chainID).prefix(k))
        guard urls.count >= m else {
            return .failed(reason: "RPC quorum needs \(m) endpoints, \(urls.count) available", kind: nil, fallback: nil, attempted: [], errors: [])
        }
        let body: Data
        do {
            body = try Self.encodeRequest(method: method, params: params)
        } catch {
            return .failed(reason: "unencodable request", kind: nil, fallback: nil, attempted: [], errors: [error])
        }
        let run = QuorumRun(urls: urls, m: m, allowDirectFallback: allowDirectFallback)
        let rejectNull = options.rejectNull
        return await run.run(timeout: timeout) { [self] url in
            await self.callEndpoint(url, body: body, timeout: endpointTimeout, chainID: chainID, rejectNull: rejectNull)
        }
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
