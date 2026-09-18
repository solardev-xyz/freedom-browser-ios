import XCTest
@testable import Freedom

/// The generic M-of-K quorum tier and its hand-off to direct (desktop
/// `requestQuorum` / `requestDirect` parity): settle on M matching,
/// fail when agreement is impossible, keep members running for a
/// following direct tier, reuse a member instead of a new request,
/// and label a user's own endpoint `userConfigured`.
@MainActor
final class ChainDataQuorumTests: XCTestCase {
    private var bundle: ChainStackBundle!

    /// Per-host scripted answers. A held host waits for `release` (or the
    /// request's timeout, like a real endpoint that never answers) and
    /// observes cancellation when the wave settles without it.
    final class Transport: @unchecked Sendable {
        private let lock = NSLock()
        var answers: [String: Result<Data, Error>] = [:]
        var delays: [String: TimeInterval] = [:]
        var held: Set<String> = []
        private var waiters: [String: [CheckedContinuation<Void, Error>]] = [:]
        private(set) var hits: [String] = []
        private(set) var hitTimes: [String: ContinuousClock.Instant] = [:]
        private(set) var cancelled: [String] = []

        var closure: ChainDataRouter.Transport {
            { [self] url, _, timeout in
                let host = url.host ?? ""
                lock.withLock { hits.append(host); hitTimes[host] = .now }
                if lock.withLock({ held.contains(host) }) {
                    do {
                        try await RPCSession.withTimeout(seconds: timeout) { try await self.waitForRelease(host) }
                    } catch is CancellationError {
                        lock.withLock { cancelled.append(host) }
                        throw CancellationError()
                    }
                }
                if let delay = lock.withLock({ delays[host] }) {
                    try await Task.sleep(for: .seconds(delay))
                }
                guard let answer = lock.withLock({ answers[host] }) else { throw URLError(.cannotConnectToHost) }
                return try answer.get()
            }
        }

        private func waitForRelease(_ host: String) async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { c.resume(throwing: CancellationError()); return }
                    lock.withLock { waiters[host, default: []].append(c) }
                }
            } onCancel: {
                let pending = lock.withLock { waiters.removeValue(forKey: host) ?? [] }
                pending.forEach { $0.resume(throwing: CancellationError()) }
            }
        }

        func release(_ host: String, with answer: Result<Data, Error>) {
            let pending = lock.withLock {
                answers[host] = answer
                held.remove(host)
                return waiters.removeValue(forKey: host) ?? []
            }
            pending.forEach { $0.resume() }
        }
    }

    private let page = RoutingContext(origin: "swap.example")
    private let call: [Any] = [["to": "0x00000095643CFfA7D9fae407a84dfCB6406456c6", "data": "0x1234"], "latest"]

    override func setUp() async throws {
        try await super.setUp()
        bundle = try ChainStackBundle(orderer: { $0 })
        bundle.chainStore.updateRPCURLs(forChainID: 1, ["https://a.example", "https://b.example", "https://c.example"])
    }

    private func router(
        _ transport: Transport, order: [ChainSource], sources: [ChainDataSource] = [], timeoutMs: Int = 500
    ) -> ChainDataRouter {
        bundle.registry.verifiedSources = sources
        var policy = ChainAccessPolicy.default(forChainID: 1)
        policy.readOrder = order
        policy.quorumTimeoutMs = timeoutMs
        bundle.registry.policyOverrides[1] = policy
        let r = ChainDataRouter(registry: bundle.registry, transport: transport.closure)
        r.interactiveDeadline = 0.05
        return r
    }

    // MARK: - Agreement

    func testSettlesAsSoonAsEnoughMembersAgree() async throws {
        let transport = Transport()
        transport.answers["a.example"] = .success(try rpcResult("0x42"))
        transport.answers["b.example"] = .success(try rpcResult("0x42"))
        transport.held = ["c.example"]
        let r = try await router(transport, order: [.quorum]).request(chainID: 1, method: "eth_call", params: call)
        XCTAssertEqual(r.result as? String, "0x42")
        XCTAssertEqual(r.source, .quorum)
        XCTAssertEqual(r.trust.level, .verified)
        XCTAssertEqual(r.trust.method, .quorum)
        XCTAssertEqual(Set(r.trust.agreed), ["a.example", "b.example"])
        XCTAssertEqual(r.trust.queried, ["a.example", "b.example", "c.example"])
        XCTAssertEqual(r.trust.k, 3)
        XCTAssertEqual(r.trust.m, 2)
        XCTAssertEqual(r.trust.block.number, 0, "generic quorum is unpinned")
        while transport.cancelled.isEmpty { await Task.yield() }
        XCTAssertEqual(transport.cancelled, ["c.example"], "the straggler is cancelled once the wave settles")
    }

    func testAgreementOnARevertIsAVerifiedRevert() async throws {
        let transport = Transport()
        transport.answers["a.example"] = .success(try rpcError(code: 3, message: "execution reverted", dataHex: "0x08c379a0"))
        transport.answers["b.example"] = .success(try rpcError(code: 3, message: "execution reverted", dataHex: "0x08c379a0"))
        transport.answers["c.example"] = .success(try rpcResult("0x1"))
        do {
            _ = try await router(transport, order: [.quorum, .direct]).request(chainID: 1, method: "eth_call", params: call)
            XCTFail("expected revert")
        } catch WalletRPC.Error.rpc(let code, _) {
            XCTAssertEqual(code, 3)
        }
        XCTAssertEqual(transport.hits.count, 3, "no direct request after a verified revert")
    }

    func testDisagreementFallsBackToDirectWithDissentEvidence() async throws {
        let transport = Transport()
        transport.answers["a.example"] = .success(try rpcResult("0x1"))
        transport.answers["b.example"] = .success(try rpcResult("0x2"))
        transport.answers["c.example"] = .success(try rpcResult("0x3"))
        let r = try await router(transport, order: [.quorum, .direct]).request(chainID: 1, method: "eth_call", params: call, context: page)
        XCTAssertEqual(r.source, .direct)
        XCTAssertEqual(r.trust.level, .userConfigured, "a.example is a URL this suite added, so it is the user's own")
        XCTAssertEqual(r.trust.agreed, ["a.example"], "highest-priority member reused")
        XCTAssertEqual(Set(r.trust.dissented), ["b.example", "c.example"], "the disagreement travels with the answer")
        XCTAssertEqual(r.trust.k, 3)
        XCTAssertEqual(r.trust.m, 2)
        XCTAssertEqual(transport.hits.count, 3, "direct consumed the member's answer, no fourth request")
    }

    func testQuorumNeedsMEndpointsElseDirect() async throws {
        bundle.chainStore.updateRPCURLs(forChainID: 1, ["https://a.example"])
        let transport = Transport()
        transport.answers["a.example"] = .success(try rpcResult("0x1"))
        let r = try await router(transport, order: [.quorum, .direct]).request(chainID: 1, method: "eth_blockNumber", params: [])
        XCTAssertEqual(r.source, .direct)
        XCTAssertEqual(transport.hits, ["a.example"])
    }

    // MARK: - Deadlines

    func testCarriesInFlightWorkPastTheQuorumDeadlineWithoutRestarting() async throws {
        bundle.chainStore.updateRPCURLs(forChainID: 1, ["https://a.example", "https://b.example", "https://c.example", "https://d.example"])
        let transport = Transport()
        transport.held = ["a.example", "b.example", "c.example"]
        transport.answers["d.example"] = .success(try rpcResult("0xrpc"))
        let router = router(transport, order: [.quorum, .direct], timeoutMs: 300)

        let started = ContinuousClock.now
        let first = try await router.request(chainID: 1, method: "eth_call", params: call, context: page)
        XCTAssertEqual(first.result as? String, "0xrpc")
        XCTAssertEqual(first.source, .direct)
        XCTAssertEqual(transport.hits, ["a.example", "b.example", "c.example", "d.example"])
        // Verification stopped at 50 ms, but the three legs stayed alive
        // under the direct tier's 300 ms budget before d was asked.
        let dAsked = transport.hitTimes["d.example"]!
        XCTAssertGreaterThan(started.duration(to: dAsked), .milliseconds(250))

        // The timed-out route is bypassed: one fresh direct request.
        let second = try await router.request(chainID: 1, method: "eth_call", params: call, context: page)
        XCTAssertEqual(second.source, .direct)
        XCTAssertEqual(transport.hits.count, 5)
    }

    func testDoesNotExtendQuorumPastTheBudgetWhenAnotherSourcePrecedesDirect() async throws {
        let transport = Transport()
        transport.held = ["a.example", "b.example", "c.example"]
        let colibri = ChainDataRouterTests.FakeSource(.colibri)
        colibri.served["eth_call"] = "0xverified"
        let router = router(transport, order: [.quorum, .colibri, .direct], sources: [colibri], timeoutMs: 5_000)
        let started = ContinuousClock.now
        let r = try await router.request(chainID: 1, method: "eth_call", params: call, context: page)
        XCTAssertEqual(r.result as? String, "0xverified")
        XCTAssertEqual(r.source, .colibri)
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(500))
    }

    func testWalletReadStaysVerifiedWhenQuorumAgreesAfterTheInteractiveBudget() async throws {
        let transport = Transport()
        for host in ["a.example", "b.example", "c.example"] {
            transport.answers[host] = .success(try rpcResult("0x42"))
            transport.delays[host] = 0.15
        }
        let r = try await router(transport, order: [.quorum, .direct]).request(chainID: 1, method: "eth_call", params: call)
        XCTAssertEqual(r.source, .quorum, "no page is waiting: the configured timeout applies")
        XCTAssertEqual(r.trust.level, .verified)
    }

    func testQuorumKeepsTheConfiguredTimeoutAsTheLastSource() async throws {
        let transport = Transport()
        for host in ["a.example", "b.example", "c.example"] {
            transport.answers[host] = .success(try rpcResult("0x42"))
            transport.delays[host] = 0.15
        }
        let r = try await router(transport, order: [.quorum]).request(chainID: 1, method: "eth_call", params: call, context: page)
        XCTAssertEqual(r.source, .quorum)
    }

    // MARK: - Direct reuse

    func testReusesASuccessfulMemberAsDirectWhenVerificationBecomesImpossible() async throws {
        let transport = Transport()
        transport.held = ["a.example"]
        transport.answers["b.example"] = .success(try rpcError(code: -32000, message: "Out of gas"))
        transport.answers["c.example"] = .success(try rpcError(code: -32000, message: "Out of gas"))
        let router = router(transport, order: [.quorum, .direct], timeoutMs: 5_000)

        let pending = Task { try await router.request(chainID: 1, method: "eth_call", params: self.call, context: page) }
        while transport.hits.count < 3 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(20))
        transport.release("a.example", with: .success(try rpcResult("0x42")))
        let r = try await pending.value
        XCTAssertEqual(r.result as? String, "0x42")
        XCTAssertEqual(r.source, .direct)
        XCTAssertEqual(r.trust.level, .userConfigured, "a.example is a URL this suite added")
        XCTAssertEqual(r.trust.method, .direct)
        XCTAssertEqual(r.trust.agreed, ["a.example"])
        XCTAssertEqual(r.trust.dissented, [])
        XCTAssertEqual(r.trust.queried, ["a.example", "b.example", "c.example"])
        XCTAssertEqual(r.trust.k, 3)
        XCTAssertEqual(r.trust.m, 2)
        XCTAssertEqual(transport.hits.count, 3, "direct consumed the response the quorum already had")

        // Two execution-limit failures block quorum for this route: the
        // next call is one fresh direct request.
        transport.answers["a.example"] = .success(try rpcResult("0xnext"))
        let next = try await router.request(chainID: 1, method: "eth_call", params: call, context: page)
        XCTAssertEqual(next.result as? String, "0xnext")
        XCTAssertEqual(next.source, .direct)
        XCTAssertEqual(transport.hits.count, 4)
    }

    func testNoPartialReuseWhenDirectIsAbsent() async throws {
        let transport = Transport()
        transport.answers["a.example"] = .success(try rpcResult("0xsingle"))
        transport.answers["b.example"] = .success(try rpcError(code: -32000, message: "Out of gas"))
        transport.answers["c.example"] = .success(try rpcError(code: -32000, message: "Out of gas"))
        do {
            _ = try await router(transport, order: [.quorum]).request(chainID: 1, method: "eth_call", params: call)
            XCTFail("expected failure")
        } catch WalletRPC.Error.allProvidersFailed {
            // expected
        }
        XCTAssertEqual(transport.hits.count, 3)
    }

    func testDirectSkipsEndpointsTheQuorumAlreadyAsked() async throws {
        bundle.chainStore.updateRPCURLs(forChainID: 1, ["https://a.example", "https://b.example", "https://c.example", "https://d.example"])
        let transport = Transport()
        for host in ["a.example", "b.example", "c.example"] {
            transport.answers[host] = .success(try rpcError(code: -32000, message: "rate limited"))
        }
        transport.answers["d.example"] = .success(try rpcResult("0xd"))
        let r = try await router(transport, order: [.quorum, .direct]).request(chainID: 1, method: "eth_call", params: call)
        XCTAssertEqual(r.source, .direct)
        XCTAssertEqual(r.trust.agreed, ["d.example"])
        XCTAssertEqual(transport.hits, ["a.example", "b.example", "c.example", "d.example"])
    }

    // MARK: - Trust levels

    func testUsersOwnEndpointIsUserConfigured() async throws {
        bundle.chainStore.updateRPCURLs(forChainID: 1, ["https://my.node"])
        let transport = Transport()
        transport.answers["my.node"] = .success(try rpcResult("0x1"))
        let mine = try await router(transport, order: [.direct]).request(chainID: 1, method: "eth_blockNumber", params: [])
        XCTAssertEqual(mine.trust.level, .userConfigured)
        XCTAssertEqual(mine.trust.method, .direct)

        let shipped = SettingsStore.defaultPublicRpcProviders[0]
        bundle.chainStore.updateRPCURLs(forChainID: 1, [shipped])
        transport.answers[URL(string: shipped)!.host!] = .success(try rpcResult("0x1"))
        let theirs = try await router(transport, order: [.direct]).request(chainID: 1, method: "eth_blockNumber", params: [])
        XCTAssertEqual(theirs.trust.level, .unverified)
        XCTAssertTrue(bundle.chainStore.isUserAddedRPCURL("https://my.node", chainID: 1) == false, "no longer in the list")
    }

    // MARK: - Serialization

    func testStableJSONIsKeyOrderIndependent() {
        let a: [String: Any] = ["b": [1, 2, ["z": NSNull(), "y": true]], "a": "x"]
        let b: [String: Any] = ["a": "x", "b": [1, 2, ["y": true, "z": NSNull()]]]
        XCTAssertEqual(StableJSON.string(a), StableJSON.string(b))
        XCTAssertEqual(StableJSON.string(a), #"{"a":"x","b":[1,2,{"y":true,"z":null}]}"#)
        XCTAssertNotEqual(StableJSON.string("0x1"), StableJSON.string("0x01"))
    }
}
