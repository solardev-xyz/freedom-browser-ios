import XCTest
@testable import Freedom

/// The generic chain-data router (desktop `chain-data-router.js`
/// parity): policy-driven source order, provenance on every answer,
/// params normalization at the shared boundary, direct-only methods,
/// and the policy sanitizer the settings page will rely on.
@MainActor
final class ChainDataRouterTests: XCTestCase {
    private var bundle: ChainStackBundle!

    final class FakeSource: ChainDataSource {
        let sourceName: String
        let kind: ChainSource
        var available = true
        var served: [String: Any] = [:]
        var failure: Error?
        var head: UInt64?
        /// Head reported after the call; nil keeps `head`.
        var headAfter: UInt64?
        var calls: [(method: String, params: [Any])] = []

        init(_ kind: ChainSource) {
            self.kind = kind
            sourceName = kind.rawValue
        }

        func isAvailable(chainID: Int) -> Bool { available }
        func serves(method: String, params: [Any], chainID: Int) -> Bool { served.keys.contains(method) }
        func result(method: String, params: [Any], chainID: Int) async throws -> Any {
            calls.append((method, params))
            if let headAfter { head = headAfter }
            if let failure { throw failure }
            return served[method]!
        }
        func evidenceLabel(chainID: Int) -> String { "\(sourceName)-label" }
        func verifiedHead(chainID: Int) -> UInt64? { head }
    }

    /// Scripted per-host answers; records hits and the timeout each
    /// request was given.
    final class Transport: @unchecked Sendable {
        private let lock = NSLock()
        var answers: [String: Result<Data, Error>] = [:]
        private(set) var hits: [String] = []
        private(set) var timeouts: [TimeInterval] = []
        private(set) var bodies: [Data] = []

        var closure: ChainDataRouter.Transport {
            { [self] url, body, timeout in
                let host = url.host ?? ""
                lock.withLock { hits.append(host); timeouts.append(timeout); bodies.append(body) }
                guard let answer = lock.withLock({ answers[host] }) else { throw URLError(.cannotConnectToHost) }
                return try answer.get()
            }
        }

        func lastParams() -> [Any]? {
            guard let body = lock.withLock({ bodies.last }),
                  let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
            return obj["params"] as? [Any]
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        bundle = try ChainStackBundle(orderer: { $0 })
        bundle.chainStore.updateRPCURLs(forChainID: 1, ["https://a.example", "https://b.example", "https://c.example"])
    }

    private func router(_ transport: Transport, sources: [ChainDataSource] = []) -> ChainDataRouter {
        bundle.registry.verifiedSources = sources
        return ChainDataRouter(registry: bundle.registry, transport: transport.closure)
    }

    // MARK: - Provenance

    func testMyotisAnswerCarriesVerifiedTrustAndStableHead() async throws {
        let myotis = FakeSource(.myotis)
        myotis.served["eth_getBalance"] = "0x1"
        myotis.head = 100
        let r = try await router(Transport(), sources: [myotis]).request(
            chainID: 1, method: "eth_getBalance", params: ["0xabc", "latest"]
        )
        XCTAssertEqual(r.result as? String, "0x1")
        XCTAssertEqual(r.source, .myotis)
        XCTAssertEqual(r.trust.level, .verified)
        XCTAssertEqual(r.trust.method, .myotis)
        XCTAssertEqual(r.trust.block.number, 100)
        XCTAssertEqual(r.trust.agreed, ["myotis-label"])
        XCTAssertEqual(r.trust.k, 1)
    }

    func testMovedHeadIsNotAttachedToTheAnswer() async throws {
        let myotis = FakeSource(.myotis)
        myotis.served["eth_getBalance"] = "0x1"
        myotis.head = 100
        myotis.headAfter = 101
        let r = try await router(Transport(), sources: [myotis]).request(
            chainID: 1, method: "eth_getBalance", params: ["0xabc", "latest"]
        )
        XCTAssertEqual(r.trust.block.number, 0, "a head that moved during the call is not the call's block")
    }

    func testColibriAnswerNamesTheProver() async throws {
        let colibri = FakeSource(.colibri)
        colibri.served["eth_call"] = "0x2"
        let r = try await router(Transport(), sources: [colibri]).request(
            chainID: 1, method: "eth_call", params: [["to": "0xabc", "data": "0x01"], "latest"]
        )
        XCTAssertEqual(r.source, .colibri)
        XCTAssertEqual(r.trust.method, .colibri)
        XCTAssertEqual(r.trust.queried, ["colibri-label"])
    }

    func testDirectAnswerIsUnverifiedAndNamesTheEndpoint() async throws {
        // A shipped endpoint (Gnosis seed) answers: unverified. A URL the
        // user added (the mainnet list this suite replaces) would be
        // `userConfigured` instead.
        let host = ChainRegistry.gnosisURLs[0].host!
        let transport = Transport()
        transport.answers[host] = .success(try rpcResult("0x3"))
        let r = try await router(transport).request(chainID: 100, method: "eth_blockNumber", params: [])
        XCTAssertEqual(r.result as? String, "0x3")
        XCTAssertEqual(r.source, .direct)
        XCTAssertEqual(r.trust.level, .unverified)
        XCTAssertEqual(r.trust.method, .direct)
        XCTAssertEqual(r.trust.agreed, [host])
        XCTAssertEqual(r.trust.queried, [host])

        transport.answers["a.example"] = .success(try rpcResult("0x3"))
        let mine = try await router(transport).request(chainID: 1, method: "eth_blockNumber", params: [])
        XCTAssertEqual(mine.trust.level, .userConfigured)
    }

    func testDirectUsesTheConfiguredSourceTimeout() async throws {
        let transport = Transport()
        transport.answers["a.example"] = .success(try rpcResult("0x3"))
        var policy = ChainAccessPolicy(readOrder: [.direct], broadcastOrder: [.direct])
        policy.quorumTimeoutMs = 7_000
        bundle.registry.policyOverrides[1] = policy
        _ = try await router(transport).request(chainID: 1, method: "eth_blockNumber", params: [])
        XCTAssertEqual(transport.timeouts, [7.0])
    }

    // MARK: - Policy order

    func testPolicyOrderIsHonoured() async throws {
        let myotis = FakeSource(.myotis)
        myotis.served["eth_getBalance"] = "0x1"
        let colibri = FakeSource(.colibri)
        colibri.served["eth_getBalance"] = "0x2"
        bundle.registry.policyOverrides[1] = ChainAccessPolicy(readOrder: [.colibri, .myotis, .direct], broadcastOrder: [.direct])
        let r = try await router(Transport(), sources: [myotis, colibri]).request(
            chainID: 1, method: "eth_getBalance", params: ["0xabc", "latest"]
        )
        XCTAssertEqual(r.source, .colibri)
        XCTAssertTrue(myotis.calls.isEmpty)
    }

    func testDirectFirstPolicySkipsVerifiedSources() async throws {
        let myotis = FakeSource(.myotis)
        myotis.served["eth_getBalance"] = "0x1"
        bundle.registry.policyOverrides[1] = ChainAccessPolicy(readOrder: [.direct], broadcastOrder: [.direct])
        let transport = Transport()
        transport.answers["a.example"] = .success(try rpcResult("0x3"))
        let r = try await router(transport, sources: [myotis]).request(
            chainID: 1, method: "eth_getBalance", params: ["0xabc", "latest"]
        )
        XCTAssertEqual(r.source, .direct)
        XCTAssertTrue(myotis.calls.isEmpty)
    }

    func testCustomChainDefaultsNeverTouchTheLightClients() async throws {
        // A chain outside Myotis/Colibri coverage: the default policy is
        // quorum → direct even though the sources claim availability.
        try bundle.chainStore.addChain(
            id: 8453, displayName: "Base", nativeName: "Ether", nativeSymbol: "ETH", nativeDecimals: 18,
            explorerBase: "https://basescan.org", pollIntervalSeconds: 2, rpcURLs: ["https://base.example"]
        )
        let myotis = FakeSource(.myotis)
        myotis.served["eth_blockNumber"] = "0x1"
        let transport = Transport()
        transport.answers["base.example"] = .success(try rpcResult("0x9"))
        let r = try await router(transport, sources: [myotis]).request(chainID: 8453, method: "eth_blockNumber", params: [])
        XCTAssertEqual(r.source, .direct)
        XCTAssertTrue(myotis.calls.isEmpty)
        XCTAssertEqual(bundle.registry.policy(forChainID: 8453).readOrder, [.quorum, .direct])
    }

    func testDirectOnlyMethodsSkipVerifiedTiers() async throws {
        let myotis = FakeSource(.myotis)
        myotis.served["web3_clientVersion"] = "myotis/1"
        let transport = Transport()
        transport.answers["a.example"] = .success(try rpcResult("geth/1"))
        let r = try await router(transport, sources: [myotis]).request(chainID: 1, method: "web3_clientVersion", params: [])
        XCTAssertEqual(r.result as? String, "geth/1")
        XCTAssertTrue(myotis.calls.isEmpty)
    }

    func testDeterministicSourceAnswerEndsTheWalk() async throws {
        let myotis = FakeSource(.myotis)
        myotis.served["eth_call"] = "0x"
        myotis.failure = WalletRPC.Error.rpc(code: 3, message: "execution reverted 0x08c379a0")
        let transport = Transport()
        transport.answers["a.example"] = .success(try rpcResult("0xshould-not-reach"))
        do {
            _ = try await router(transport, sources: [myotis]).request(
                chainID: 1, method: "eth_call", params: [["to": "0xabc", "data": "0x01"]]
            )
            XCTFail("expected revert")
        } catch WalletRPC.Error.rpc(let code, _) {
            XCTAssertEqual(code, 3)
        }
        XCTAssertTrue(transport.hits.isEmpty)
    }

    func testEmptyPoolReportsNoProvidersWhenNothingElseFailed() async throws {
        bundle.chainStore.updateRPCURLs(forChainID: 100, [])
        do {
            _ = try await router(Transport()).request(chainID: 100, method: "eth_blockNumber", params: [])
            XCTFail("expected noProviders")
        } catch WalletRPC.Error.noProviders {
            // expected
        }
    }

    func testExhaustedPoolReportsOnlyEndpointErrors() async throws {
        // Source skips (not installed, cannot serve) are not provider
        // failures: `allProvidersFailed` counts endpoints, as it always has.
        let myotis = FakeSource(.myotis)
        myotis.served["eth_blockNumber"] = "0x1"
        myotis.failure = ChainSourceUnavailable(reason: "syncing")
        let transport = Transport()
        transport.answers["a.example"] = .success(try rpcError(code: -32603, message: "internal"))
        transport.answers["b.example"] = .failure(URLError(.timedOut))
        do {
            _ = try await router(transport, sources: [myotis]).request(chainID: 1, method: "eth_blockNumber", params: [])
            XCTFail("expected allProvidersFailed")
        } catch WalletRPC.Error.allProvidersFailed(let errors) {
            XCTAssertEqual(errors.count, 3)
        }
        XCTAssertEqual(transport.hits, ["a.example", "b.example", "c.example"])
        XCTAssertEqual(bundle.registry.rpcURLs(forChainID: 1).map(\.host), ["a.example"], "only transport failures quarantine")
    }

    func testNullResultIsMalformedOnlyWhenRejected() async throws {
        let transport = Transport()
        transport.answers["a.example"] = .success(try rpcResult(NSNull()))
        transport.answers["b.example"] = .success(try rpcResult("0x1"))
        // Lenient first: null is a well-defined absence, nothing is quarantined.
        let lenient = try await router(transport).request(chainID: 1, method: "eth_getTransactionByHash", params: ["0xh"])
        XCTAssertTrue(lenient.result is NSNull)
        XCTAssertEqual(transport.hits, ["a.example"])
        // Strict: null is malformed, the endpoint is quarantined, the next answers.
        let strict = try await router(transport).request(
            chainID: 1, method: "eth_getTransactionByHash", params: ["0xh"], options: .init(rejectNull: true)
        )
        XCTAssertEqual(strict.result as? String, "0x1")
        XCTAssertEqual(strict.trust.agreed, ["b.example"])
        XCTAssertEqual(bundle.registry.rpcURLs(forChainID: 1).map(\.host), ["b.example", "c.example"])
    }

    // MARK: - Params normalization (shared boundary)

    func testDecimalQuantitiesAreHexEncodedForEveryTier() async throws {
        let transport = Transport()
        transport.answers["a.example"] = .success(try rpcResult("0x5208"))
        _ = try await router(transport).request(
            chainID: 1, method: "eth_estimateGas",
            params: [["from": "0xa", "to": "0xb", "value": "1000000000000000000", "gas": 21000]]
        )
        let call = transport.lastParams()?.first as? [String: Any]
        XCTAssertEqual(call?["value"] as? String, "0xde0b6b3a7640000")
        XCTAssertEqual(call?["gas"] as? String, "0x5208")
    }

    func testInputAliasIsCanonicalisedIntoData() {
        let out = ChainCallShape.normalizeParams(
            method: "eth_call", params: [["to": "0xb", "input": "0xabcd"], "latest"]
        )
        let call = out.first as? [String: Any]
        XCTAssertEqual(call?["data"] as? String, "0xabcd")
        XCTAssertEqual(call?["input"] as? String, "0xabcd")
        XCTAssertEqual(out.count, 2)
    }

    func testInputWinsOverEmptyDataPlaceholder() {
        let out = ChainCallShape.normalizeParams(method: "eth_call", params: [["to": "0xb", "data": "0x", "input": "0x01"]])
        XCTAssertEqual((out.first as? [String: Any])?["data"] as? String, "0x01")
    }

    func testHexQuantitiesAreMinimisedAndOthersLeftAlone() {
        XCTAssertEqual(ChainCallShape.quantityHex("0x0001"), "0x1")
        XCTAssertEqual(ChainCallShape.quantityHex("42"), "0x2a")
        XCTAssertEqual(ChainCallShape.quantityHex(NSNumber(value: 7)), "0x7")
        XCTAssertNil(ChainCallShape.quantityHex(NSNumber(value: true)))
        XCTAssertNil(ChainCallShape.quantityHex("0xzz"))
        XCTAssertNil(ChainCallShape.quantityHex("latest"))
        let untouched = ChainCallShape.normalizeParams(method: "eth_getBalance", params: ["0xa", "latest"])
        XCTAssertEqual(untouched as? [String], ["0xa", "latest"])
    }

    // MARK: - Routing context

    func testRoutingContextNormalization() {
        XCTAssertNil(RoutingContext(origin: nil).origin)
        XCTAssertNil(RoutingContext(origin: "   ").origin)
        XCTAssertNil(RoutingContext(origin: "a\u{01}b").origin)
        XCTAssertNil(RoutingContext(origin: String(repeating: "x", count: 2_049)).origin)
        XCTAssertEqual(RoutingContext(origin: "  bafyCID ").origin, "bafyCID", "case preserved, whitespace trimmed")
        XCTAssertTrue(RoutingContext(origin: "app.eth").isInteractive)
        XCTAssertFalse(RoutingContext.wallet.isInteractive)
    }

    // MARK: - Policy sanitizer

    func testDefaultsMatchDesktop() {
        let mainnet = ChainAccessPolicy.default(forChainID: 1)
        XCTAssertEqual(mainnet.readOrder, [.myotis, .colibri, .quorum, .direct])
        XCTAssertEqual(mainnet.broadcastOrder, [.myotis, .direct])
        XCTAssertEqual(mainnet.quorumK, 3)
        XCTAssertEqual(mainnet.quorumM, 2)
        XCTAssertEqual(mainnet.quorumTimeoutMs, 5_000)
        let base = ChainAccessPolicy.default(forChainID: 8453)
        XCTAssertEqual(base.readOrder, [.quorum, .direct])
        XCTAssertEqual(base.broadcastOrder, [.direct])
    }

    func testSanitizerDropsDuplicatesUnsupportedAndEmpty() {
        let messy = ChainAccessPolicy(
            readOrder: [.direct, .myotis, .direct, .colibri],
            broadcastOrder: [.colibri, .quorum],
            quorumK: 0, quorumM: 9, quorumTimeoutMs: 10, proverURL: "  ", zkProof: false
        )
        let mainnet = messy.sanitized(forChainID: 1)
        XCTAssertEqual(mainnet.readOrder, [.direct, .myotis, .colibri])
        XCTAssertEqual(mainnet.broadcastOrder, [.direct], "non-broadcasters dropped, never empty")
        XCTAssertEqual(mainnet.quorumK, 1)
        XCTAssertEqual(mainnet.quorumM, 1)
        XCTAssertEqual(mainnet.quorumTimeoutMs, 500)
        XCTAssertNil(mainnet.proverURL)
        let base = messy.sanitized(forChainID: 8453)
        XCTAssertEqual(base.readOrder, [.direct], "light-client tiers are not available off 1/100")
        XCTAssertEqual(ChainAccessPolicy.supportedSources(forChainID: 8453), [.quorum, .direct])
    }

    func testPolicyRoundTripsThroughJSON() throws {
        let policy = ChainAccessPolicy(readOrder: [.quorum, .direct], broadcastOrder: [.direct], quorumK: 4, quorumM: 3, quorumTimeoutMs: 800, proverURL: "https://p.example", zkProof: false)
        let data = try JSONEncoder().encode(policy)
        XCTAssertEqual(try JSONDecoder().decode(ChainAccessPolicy.self, from: data), policy)
        XCTAssertEqual(ENSResolutionMethod.selectableCases, [.colibri, .quorum, .userConfigured], "direct never enters the ENS picker")
    }
}
