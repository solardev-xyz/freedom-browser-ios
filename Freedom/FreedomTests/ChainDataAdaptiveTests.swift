import XCTest
import SwiftData
@testable import Freedom

/// The router's adaptive layer (desktop commits 3e0caa5b / 01dd4862):
/// interactive deadlines, escalating per-route cooldowns, session
/// blocks for execution ceilings, Myotis serialization with a bounded
/// queue, Colibri admission, and non-cancellable work that never
/// starves a fallback.
@MainActor
final class ChainDataAdaptiveTests: XCTestCase {
    private var bundle: ChainStackBundle!
    private var clock: MutableClock!

    /// A source whose calls can be held open until the test releases
    /// them, or scripted to fail.
    final class GateSource: ChainDataSource {
        let sourceName: String
        let kind: ChainSource
        var served: [String: Any] = [:]
        var failure: Error?
        var hold = false
        var calls = 0
        private var held: [CheckedContinuation<Void, Never>] = []

        init(_ kind: ChainSource) {
            self.kind = kind
            sourceName = kind.rawValue
        }

        func isAvailable(chainID: Int) -> Bool { true }
        func serves(method: String, params: [Any], chainID: Int) -> Bool { served.keys.contains(method) }
        func result(method: String, params: [Any], chainID: Int) async throws -> Any {
            calls += 1
            if hold {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in held.append(c) }
            }
            if let failure { throw failure }
            return served[method]!
        }

        var heldCount: Int { held.count }

        func release() {
            let pending = held
            held.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    final class Transport: @unchecked Sendable {
        private let lock = NSLock()
        var answer: Data?
        private(set) var hits = 0
        private(set) var timeouts: [TimeInterval] = []
        var closure: ChainDataRouter.Transport {
            { [self] _, _, timeout in
                lock.withLock { hits += 1; timeouts.append(timeout) }
                guard let answer = lock.withLock({ answer }) else { throw URLError(.cannotConnectToHost) }
                return answer
            }
        }
    }

    private let page = RoutingContext(origin: "app.eth")
    private let otherPage = RoutingContext(origin: "other.eth")
    private let balanceParams: [Any] = ["0x00000095643cffa7d9fae407a84dfcb6406456c6", "latest"]

    override func setUp() async throws {
        try await super.setUp()
        bundle = try ChainStackBundle(orderer: { $0 })
        bundle.chainStore.updateRPCURLs(forChainID: 1, ["https://a.example"])
        clock = MutableClock(now: Date(timeIntervalSince1970: 1_000_000))
    }

    private func router(
        _ transport: Transport, sources: [ChainDataSource], order: [ChainSource]? = nil, timeoutMs: Int = 500
    ) -> ChainDataRouter {
        bundle.registry.verifiedSources = sources
        var policy = ChainAccessPolicy.default(forChainID: 1)
        if let order { policy.readOrder = order }
        policy.quorumTimeoutMs = timeoutMs
        bundle.registry.policyOverrides[1] = policy
        let clock = self.clock!
        let r = ChainDataRouter(registry: bundle.registry, transport: transport.closure, clock: { clock.now })
        r.interactiveDeadline = 0.05
        return r
    }

    private func directAnswer(_ transport: Transport, _ value: String = "0xd") throws {
        transport.answer = try rpcResult(value)
    }

    // MARK: - Deadlines

    func testInteractiveReadFallsThroughAtTheDeadlineAndBypassesTheRoute() async throws {
        let colibri = GateSource(.colibri)
        colibri.served["eth_getBalance"] = "0xc"
        colibri.hold = true
        let transport = Transport()
        try directAnswer(transport)
        let router = router(transport, sources: [colibri], order: [.colibri, .direct])

        let started = ContinuousClock.now
        let first = try await router.request(chainID: 1, method: "eth_getBalance", params: balanceParams, context: page)
        XCTAssertEqual(first.source, .direct)
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(400), "fell through at the interactive deadline")
        XCTAssertEqual(colibri.calls, 1)
        XCTAssertEqual(router.admission.colibriInFlightCount, 1, "the prover call is still tracked")

        // Same page, same target: the route is on cooldown, Colibri is not asked.
        let second = try await router.request(chainID: 1, method: "eth_getBalance", params: balanceParams, context: page)
        XCTAssertEqual(second.source, .direct)
        XCTAssertEqual(colibri.calls, 1, "timed-out route is bypassed")

        // A wallet read has no route key and still asks Colibri (with the
        // configured timeout, so it falls through too — 500 ms here).
        colibri.hold = false
        colibri.release()
        let wallet = try await router.request(chainID: 1, method: "eth_getBalance", params: balanceParams)
        XCTAssertEqual(wallet.source, .colibri)
        XCTAssertEqual(colibri.calls, 2)
        XCTAssertEqual(router.admission.colibriInFlightCount, 0, "released once the held call settled")
    }

    func testLastConfiguredSourceKeepsTheConfiguredTimeout() async throws {
        let colibri = GateSource(.colibri)
        colibri.served["eth_getBalance"] = "0xc"
        colibri.hold = true
        let router = router(Transport(), sources: [colibri], order: [.colibri])
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            colibri.hold = false
            colibri.release()
        }
        // 150 ms is past the 50 ms interactive deadline but inside the
        // 500 ms configured timeout — the read still succeeds, verified.
        let r = try await router.request(chainID: 1, method: "eth_getBalance", params: balanceParams, context: page)
        XCTAssertEqual(r.source, .colibri)
        XCTAssertEqual(r.trust.level, .verified)
    }

    func testWalletReadKeepsVerificationPastTheInteractiveBudget() async throws {
        let myotis = GateSource(.myotis)
        myotis.served["eth_getBalance"] = "0xa"
        myotis.hold = true
        let transport = Transport()
        try directAnswer(transport)
        let router = router(transport, sources: [myotis], order: [.myotis, .direct])
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            myotis.hold = false
            myotis.release()
        }
        let r = try await router.request(chainID: 1, method: "eth_getBalance", params: balanceParams)
        XCTAssertEqual(r.source, .myotis, "no page is waiting: the configured timeout applies")
        XCTAssertEqual(transport.hits, 0)
    }

    func testDirectTierNeverGetsTheInteractiveDeadline() async throws {
        let transport = Transport()
        try directAnswer(transport)
        let router = router(transport, sources: [], order: [.direct], timeoutMs: 3_000)
        _ = try await router.request(chainID: 1, method: "eth_blockNumber", params: [], context: page)
        XCTAssertEqual(transport.timeouts, [3.0])
    }

    // MARK: - Cooldowns and session blocks

    func testTimeoutCooldownsEscalateAndResetOnSuccess() async throws {
        let colibri = GateSource(.colibri)
        colibri.served["eth_getBalance"] = "0xc"
        colibri.failure = ChainSourceUnavailable(reason: "prover timed out", kind: .timeout)
        let transport = Transport()
        try directAnswer(transport)
        let router = router(transport, sources: [colibri], order: [.colibri, .direct])
        let key = AdaptiveRouting.routeKey(source: .colibri, chainID: 1, method: "eth_getBalance", params: balanceParams, context: page)!

        func read() async throws -> ChainSource {
            try await router.request(chainID: 1, method: "eth_getBalance", params: balanceParams, context: page).source
        }

        _ = try await read()
        XCTAssertEqual(colibri.calls, 1)
        clock.advance(by: 14)
        _ = try await read()
        XCTAssertEqual(colibri.calls, 1, "15 s cooldown after the first timeout")
        clock.advance(by: 2)
        _ = try await read()
        XCTAssertEqual(colibri.calls, 2, "retried once the cooldown lapsed")
        clock.advance(by: 29)
        _ = try await read()
        XCTAssertEqual(colibri.calls, 2, "30 s cooldown after the second")
        clock.advance(by: 2)
        _ = try await read()
        XCTAssertEqual(colibri.calls, 3)
        XCTAssertEqual(router.adaptive.state(key)?.timeoutCount, 3)
        clock.advance(by: 59)
        _ = try await read()
        XCTAssertEqual(colibri.calls, 3, "60 s cooldown after the third, and it caps there")

        // A success clears the escalation entirely.
        clock.advance(by: 2)
        colibri.failure = nil
        let recovered = try await read()
        XCTAssertEqual(recovered, .colibri)
        XCTAssertNil(router.adaptive.state(key))
        colibri.failure = ChainSourceUnavailable(reason: "prover timed out", kind: .timeout)
        _ = try await read()
        XCTAssertEqual(router.adaptive.state(key)?.timeoutCount, 1, "back to the 15 s step")
    }

    func testExecutionLimitBlocksOnlyTheMatchingAppAndTarget() async throws {
        let colibri = GateSource(.colibri)
        colibri.served["eth_call"] = "0xc"
        colibri.failure = ChainSourceUnavailable(reason: "EVM execution failed: out of gas")
        let transport = Transport()
        try directAnswer(transport)
        let router = router(transport, sources: [colibri], order: [.colibri, .direct])
        let heavy: [Any] = [["to": "0x00000095643CFfA7D9fae407a84dfCB6406456c6", "data": "0x01"], "latest"]
        let other: [Any] = [["to": "0x1111111111111111111111111111111111111111", "data": "0x01"], "latest"]

        _ = try await router.request(chainID: 1, method: "eth_call", params: heavy, context: page)
        XCTAssertEqual(colibri.calls, 1)
        // The prover recovers, but the heavy route stays blocked for the session.
        colibri.failure = nil
        clock.advance(by: 3_600)
        let blocked = try await router.request(chainID: 1, method: "eth_call", params: heavy, context: page)
        XCTAssertEqual(blocked.source, .direct)
        XCTAssertEqual(colibri.calls, 1, "a capacity failure blocks the route for the session, not a cooldown")

        let otherApp = try await router.request(chainID: 1, method: "eth_call", params: heavy, context: otherPage)
        XCTAssertEqual(otherApp.source, .colibri, "another app's route is untouched")
        let otherTarget = try await router.request(chainID: 1, method: "eth_call", params: other, context: page)
        XCTAssertEqual(otherTarget.source, .colibri, "another target on the same app is untouched")
        XCTAssertEqual(colibri.calls, 3)

        // Lighter calls succeeding never lift the block.
        let again = try await router.request(chainID: 1, method: "eth_call", params: heavy, context: page)
        XCTAssertEqual(again.source, .direct, "the blocked route stayed blocked")
        XCTAssertEqual(colibri.calls, 3)
    }

    func testAdaptiveStateIsBoundedFIFO() async {
        let adaptive = AdaptiveRouting(clock: { self.clock.now })
        for i in 0..<(AdaptiveRouting.maxRoutes + 5) {
            adaptive.recordFailure("route-\(i)", kind: .timeout)
        }
        XCTAssertEqual(adaptive.count, AdaptiveRouting.maxRoutes)
        XCTAssertNil(adaptive.state("route-0"), "oldest evicted")
        XCTAssertNotNil(adaptive.state("route-\(AdaptiveRouting.maxRoutes + 4)"))
        XCTAssertNil(AdaptiveRouting.routeKey(source: .colibri, chainID: 1, method: "eth_call", params: [], context: .wallet))
        XCTAssertEqual(AdaptiveRouting.requestTarget(method: "eth_getLogs", params: [["address": ["0xB", "0xA"]]]), "*")
        XCTAssertEqual(
            AdaptiveRouting.requestTarget(method: "eth_getLogs", params: [["address": [
                "0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            ]]]),
            "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        )
    }

    // MARK: - Myotis admission

    func testConcurrentMyotisReadsAreSerializedNotDowngraded() async throws {
        let myotis = GateSource(.myotis)
        myotis.served["eth_getBalance"] = "0xa"
        myotis.hold = true
        let transport = Transport()
        try directAnswer(transport)
        let router = router(transport, sources: [myotis], order: [.myotis, .direct], timeoutMs: 5_000)

        async let first = router.request(chainID: 1, method: "eth_getBalance", params: balanceParams)
        async let second = router.request(chainID: 1, method: "eth_getBalance", params: balanceParams)
        // Let both reach the source: one executes, one queues.
        while myotis.heldCount < 1 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(myotis.calls, 1, "the second read waits for the slot instead of running concurrently")
        XCTAssertEqual(router.admission.myotisQueueDepth(chainID: 1), 1)

        myotis.release()
        // The queued read is handed the slot and runs; release it too.
        while myotis.calls < 2 { await Task.yield() }
        myotis.hold = false
        myotis.release()
        let results = try await [first, second]
        XCTAssertEqual(results.map(\.source), [.myotis, .myotis])
        XCTAssertEqual(transport.hits, 0)
        XCTAssertEqual(router.admission.myotisInFlightCount(chainID: 1), 0)
    }

    func testMyotisQueueFullFallsThroughImmediately() async throws {
        let myotis = GateSource(.myotis)
        myotis.served["eth_getBalance"] = "0xa"
        myotis.hold = true
        let transport = Transport()
        try directAnswer(transport)
        let router = router(transport, sources: [myotis], order: [.myotis, .direct], timeoutMs: 5_000)

        var pending: [Task<ChainDataResult, Error>] = []
        for _ in 0..<(SourceAdmission.maxMyotisInFlight + SourceAdmission.maxMyotisQueued) {
            pending.append(Task { try await router.request(chainID: 1, method: "eth_getBalance", params: self.balanceParams) })
        }
        while router.admission.myotisQueueDepth(chainID: 1) < SourceAdmission.maxMyotisQueued { await Task.yield() }

        let started = ContinuousClock.now
        let overflow = try await router.request(chainID: 1, method: "eth_getBalance", params: balanceParams)
        XCTAssertEqual(overflow.source, .direct, "refused at the queue cap, not parked")
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(200))

        // Drain: every held call is released in turn.
        myotis.hold = false
        while myotis.calls < pending.count {
            myotis.release()
            await Task.yield()
        }
        myotis.release()
        for task in pending { _ = try await task.value }
        XCTAssertEqual(router.admission.myotisInFlightCount(chainID: 1), 0)
        XCTAssertEqual(router.admission.myotisQueueDepth(chainID: 1), 0)
    }

    func testNonCancellableMyotisWorkDoesNotStarveInteractiveFallbacks() async throws {
        let myotis = GateSource(.myotis)
        myotis.served["eth_getBalance"] = "0xa"
        myotis.hold = true
        let transport = Transport()
        try directAnswer(transport)
        let router = router(transport, sources: [myotis], order: [.myotis, .direct], timeoutMs: 5_000)

        let first = try await router.request(chainID: 1, method: "eth_getBalance", params: balanceParams, context: page)
        XCTAssertEqual(first.source, .direct, "the page got an answer at the deadline")
        XCTAssertEqual(router.admission.myotisInFlightCount(chainID: 1), 1, "the engine still holds its slot")

        // A second interactive read for another target queues behind the
        // stuck slot, gives up at its own deadline and abandons the queue.
        let otherTarget: [Any] = ["0x1111111111111111111111111111111111111111", "latest"]
        let second = try await router.request(chainID: 1, method: "eth_getBalance", params: otherTarget, context: page)
        XCTAssertEqual(second.source, .direct)
        XCTAssertEqual(router.admission.myotisQueueDepth(chainID: 1), 0, "an abandoned waiter leaves the queue")
        XCTAssertEqual(myotis.calls, 1)

        // Once the engine settles, the slot frees and Myotis serves again.
        myotis.hold = false
        myotis.release()
        while router.admission.myotisInFlightCount(chainID: 1) > 0 { await Task.yield() }
        let later = try await router.request(chainID: 1, method: "eth_getBalance", params: otherTarget, context: otherPage)
        XCTAssertEqual(later.source, .myotis)
    }

    func testSlotHandedOverAtTheDeadlineIsPassedAlong() async throws {
        // A queued waiter whose deadline fires exactly as the slot is
        // granted must release it rather than leak it.
        let admission = SourceAdmission()
        XCTAssertEqual(admission.acquireMyotis(chainID: 1).map { if case .immediate = $0 { return true } else { return false } }, true)
        guard case .queued(let waiter)? = admission.acquireMyotis(chainID: 1) else { return XCTFail("expected a queued slot") }
        admission.releaseMyotis(chainID: 1)   // hands the slot to `waiter`
        XCTAssertTrue(waiter.granted)
        admission.abandonMyotis(chainID: 1, waiter: waiter)
        XCTAssertEqual(admission.myotisInFlightCount(chainID: 1), 0, "passed along, not leaked")
    }

    // MARK: - Colibri admission

    func testColibriPerRouteAndGlobalCaps() async throws {
        let colibri = GateSource(.colibri)
        colibri.served["eth_call"] = "0xc"
        colibri.hold = true
        let transport = Transport()
        try directAnswer(transport)
        let router = router(transport, sources: [colibri], order: [.colibri, .direct], timeoutMs: 5_000)
        let call: [Any] = [["to": "0x00000095643CFfA7D9fae407a84dfCB6406456c6", "data": "0x01"], "latest"]
        let otherCall: [Any] = [["to": "0x1111111111111111111111111111111111111111", "data": "0x01"], "latest"]

        // Two wallet reads on one target hold the route's two slots.
        async let a = router.request(chainID: 1, method: "eth_call", params: call)
        async let b = router.request(chainID: 1, method: "eth_call", params: call)
        while colibri.heldCount < 2 { await Task.yield() }
        XCTAssertEqual(router.admission.colibriInFlightCount, 2)

        // A third on the same route is refused at once — no prover call.
        let third = try await router.request(chainID: 1, method: "eth_call", params: call)
        XCTAssertEqual(third.source, .direct, "per-route cap")
        XCTAssertEqual(colibri.calls, 2)

        // Global cap: fill the remaining slots, then another target is refused too.
        var filler: [String] = []
        while router.admission.colibriInFlightCount < SourceAdmission.maxColibriInFlight {
            let key = "route-\(filler.count)"
            XCTAssertTrue(router.admission.admitColibri(routeKey: key))
            filler.append(key)
        }
        let other = try await router.request(chainID: 1, method: "eth_call", params: otherCall, context: otherPage)
        XCTAssertEqual(other.source, .direct, "global cap")
        XCTAssertEqual(colibri.calls, 2)

        filler.forEach { router.admission.releaseColibri(routeKey: $0) }
        colibri.hold = false
        colibri.release()
        let results = try await [a, b]
        XCTAssertEqual(results.map(\.source), [.colibri, .colibri])
        XCTAssertEqual(router.admission.colibriInFlightCount, 0)
    }

    // MARK: - Bridge context

    func testBridgeReadsCarryThePageOrigin() async throws {
        let colibri = GateSource(.colibri)
        colibri.served["eth_call"] = "0xc"
        colibri.hold = true
        let transport = Transport()
        try directAnswer(transport)
        let router = router(transport, sources: [colibri], order: [.colibri, .direct], timeoutMs: 5_000)
        bundle.registry.walletRPC = WalletRPC(router: router)
        let container = try inMemoryContainer(for: DappPermission.self)
        let bridge = RPCRouter(
            registry: bundle.registry,
            permissionStore: PermissionStore(context: container.mainContext),
            activeChain: { .mainnet }
        )
        let started = ContinuousClock.now
        let result = try await bridge.handle(
            method: "eth_call",
            params: [["to": "0x00000095643CFfA7D9fae407a84dfCB6406456c6", "data": "0x01"], "latest"],
            origin: OriginIdentity.from(string: "https://app.example")!
        )
        XCTAssertEqual(result as? String, "0xd", "the page fell through to direct at the interactive deadline")
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        colibri.hold = false
        colibri.release()
    }
}
