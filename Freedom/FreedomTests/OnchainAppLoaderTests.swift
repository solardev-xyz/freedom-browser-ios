import XCTest
import web3
@testable import Freedom

/// The `html()` fetch rides the chain-data router and keeps provenance:
/// verified sources win and label the document verified; the direct
/// pool answers unverified with the endpoint named; disagreement is a
/// conflict; reverts are the contract's answer; dead endpoints are
/// quarantined; oversized or malformed documents are refused.
@MainActor
final class OnchainAppLoaderTests: XCTestCase {
    private var bundle: ChainStackBundle!
    private let zswap = OnchainAppRef(address: "0x00000095643CFfA7D9fae407a84dfCB6406456c6", chainID: 1)!

    private final class FakeSource: ChainDataSource {
        let sourceName: String
        let kind: ChainSource = .myotis
        var available = true
        var result: Result<Any, Error>?
        var calls = 0
        init(name: String) { sourceName = name }
        func isAvailable(chainID: Int) -> Bool { available }
        func serves(method: String, params: [Any], chainID: Int) -> Bool { method == "eth_call" }
        func result(method: String, params: [Any], chainID: Int) async throws -> Any {
            calls += 1
            guard let result else { throw ChainSourceUnavailable(reason: "no result scripted") }
            return try result.get()
        }
    }

    /// Records hits per endpoint; `answers` scripts each host's reply.
    private final class Transport: @unchecked Sendable {
        private let lock = NSLock()
        var answers: [String: Result<Data, Error>] = [:]
        private(set) var hits: [String] = []
        var closure: ChainDataRouter.Transport {
            { [self] url, _, _ in
                let host = url.host ?? ""
                lock.withLock { hits.append(host) }
                guard let answer = lock.withLock({ answers[host] }) else { throw URLError(.cannotConnectToHost) }
                return try answer.get()
            }
        }
    }

    private static func abiString(_ s: String) -> String {
        let encoder = ABIFunctionEncoder("_")
        try! encoder.encode(s)
        return Data(try! encoder.encoded().dropFirst(4)).web3.hexString
    }

    override func setUp() async throws {
        try await super.setUp()
        bundle = try ChainStackBundle(orderer: { $0 })
        bundle.chainStore.updateRPCURLs(forChainID: 1, ["https://a.example", "https://b.example"])
    }

    /// The loader reads through the registry's router; the test router
    /// carries the scripted transport. The bundle's mainnet policy is the
    /// single-shot ladder (no quorum) unless a test overrides it.
    private func loader(_ transport: Transport) -> OnchainAppLoader {
        bundle.registry.walletRPC = WalletRPC(router: ChainDataRouter(registry: bundle.registry, transport: transport.closure))
        return OnchainAppLoader(registry: bundle.registry, chainStore: bundle.chainStore)
    }

    func testVerifiedSourceAnswersWithProvenanceAndSkipsDirect() async throws {
        let myotis = FakeSource(name: "myotis")
        myotis.result = .success(Self.abiString("<p>app</p>"))
        bundle.registry.verifiedSources = [myotis]
        let transport = Transport()
        let document = try await loader(transport).load(zswap)
        XCTAssertEqual(document.html, "<p>app</p>")
        XCTAssertEqual(document.provenance.trust.level, .verified)
        XCTAssertEqual(document.provenance.trust.method, .myotis)
        XCTAssertTrue(document.provenance.isTrusted)
        XCTAssertEqual(document.provenance.htmlHash, OnchainAppRef.htmlHash("<p>app</p>"))
        XCTAssertEqual(document.provenance.networkName, "Ethereum")
        XCTAssertTrue(transport.hits.isEmpty, "verified answer must not touch the direct pool")
    }

    func testUnavailableSourceFallsThroughToDirectUnverified() async throws {
        let myotis = FakeSource(name: "myotis")
        myotis.result = .failure(ChainSourceUnavailable(reason: "warming up"))
        bundle.registry.verifiedSources = [myotis]
        let transport = Transport()
        transport.answers["a.example"] = .success(try rpcResult(Self.abiString("<p>direct</p>")))
        let document = try await loader(transport).load(zswap)
        XCTAssertEqual(document.html, "<p>direct</p>")
        // a.example is a URL the test added to the mainnet list, so it is
        // the user's own endpoint: single-source trust, by their choice.
        XCTAssertEqual(document.provenance.trust.level, .userConfigured)
        XCTAssertEqual(document.provenance.trust.method, .direct)
        XCTAssertEqual(document.provenance.source, "a.example")
        XCTAssertTrue(document.provenance.isTrusted, "the user's own endpoint loads without the gate")
        XCTAssertEqual(myotis.calls, 1)
    }

    func testPublicEndpointAnswerIsUnverifiedAndGated() async throws {
        let shipped = SettingsStore.defaultPublicRpcProviders[0]
        bundle.chainStore.updateRPCURLs(forChainID: 1, [shipped])
        let transport = Transport()
        transport.answers[URL(string: shipped)!.host!] = .success(try rpcResult(Self.abiString("<p>public</p>")))
        let document = try await loader(transport).load(zswap)
        XCTAssertEqual(document.provenance.trust.level, .unverified)
        XCTAssertFalse(document.provenance.isTrusted)
        XCTAssertFalse(document.provenance.hasConflict)
    }

    func testEndpointDisagreementIsAConflict() async throws {
        // Quorum over three shipped endpoints that all answer differently:
        // direct reuses the first member, and the dissent travels with it.
        let shipped = Array(SettingsStore.defaultPublicRpcProviders.prefix(3))
        bundle.chainStore.updateRPCURLs(forChainID: 1, shipped)
        bundle.registry.policyOverrides[1] = ChainAccessPolicy(readOrder: [.quorum, .direct], broadcastOrder: [.direct])
        let transport = Transport()
        for (i, url) in shipped.enumerated() {
            transport.answers[URL(string: url)!.host!] = .success(try rpcResult(Self.abiString("<p>v\(i)</p>")))
        }
        let document = try await loader(transport).load(zswap)
        XCTAssertTrue(document.provenance.hasConflict)
        XCTAssertFalse(document.provenance.isTrusted)
        XCTAssertEqual(document.provenance.trust.dissented.count, 2)
        XCTAssertEqual(document.html, "<p>v0</p>", "the highest-priority member's bytes are what the gate shows")
    }

    func testQuorumAgreementIsVerified() async throws {
        let shipped = Array(SettingsStore.defaultPublicRpcProviders.prefix(3))
        bundle.chainStore.updateRPCURLs(forChainID: 1, shipped)
        bundle.registry.policyOverrides[1] = ChainAccessPolicy(readOrder: [.quorum, .direct], broadcastOrder: [.direct])
        let transport = Transport()
        for url in shipped {
            transport.answers[URL(string: url)!.host!] = .success(try rpcResult(Self.abiString("<p>same</p>")))
        }
        let document = try await loader(transport).load(zswap)
        XCTAssertEqual(document.provenance.trust.level, .verified)
        XCTAssertEqual(document.provenance.trust.method, .quorum)
        XCTAssertTrue(document.provenance.isTrusted)
    }

    func testDeadEndpointIsQuarantinedAndNextOneAnswers() async throws {
        let transport = Transport()
        transport.answers["b.example"] = .success(try rpcResult(Self.abiString("<p>b</p>")))
        let document = try await loader(transport).load(zswap)
        XCTAssertEqual(document.provenance.source, "b.example")
        XCTAssertEqual(transport.hits, ["a.example", "b.example"])
        XCTAssertEqual(bundle.registry.rpcURLs(for: .mainnet).map(\.host), ["b.example"], "a.example quarantined")
    }

    func testRevertIsTheContractsAnswerNotAnEndpointFault() async {
        let transport = Transport()
        transport.answers["a.example"] = .success(try! rpcError(code: 3, message: "execution reverted", dataHex: "0x08c379a0"))
        transport.answers["b.example"] = .success(try! rpcResult(Self.abiString("<p>b</p>")))
        do {
            _ = try await loader(transport).load(zswap)
            XCTFail("expected notAnApp")
        } catch OnchainAppError.notAnApp {
            XCTAssertEqual(transport.hits, ["a.example"], "a revert ends the walk")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testVerifiedRevertIsNotAnApp() async {
        let myotis = FakeSource(name: "myotis")
        myotis.result = .failure(WalletRPC.Error.rpc(code: 3, message: "execution reverted 0x"))
        bundle.registry.verifiedSources = [myotis]
        do {
            _ = try await loader(Transport()).load(zswap)
            XCTFail("expected notAnApp")
        } catch OnchainAppError.notAnApp {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testUnknownChainAndUnreachable() async {
        do {
            _ = try await loader(Transport()).load(OnchainAppRef(address: zswap.address, chainID: 424242)!)
            XCTFail("expected unknownChain")
        } catch OnchainAppError.unknownChain(let id) {
            XCTAssertEqual(id, 424242)
        } catch { XCTFail("wrong error: \(error)") }
        do {
            _ = try await loader(Transport()).load(zswap)
            XCTFail("expected unreachable")
        } catch OnchainAppError.unreachable {
            // expected
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testOversizedDocumentIsRefused() async {
        let transport = Transport()
        let huge = "0x" + String(repeating: "00", count: OnchainAppRef.maxHTMLBytes + 96)
        transport.answers["a.example"] = .success(try! rpcResult(huge))
        do {
            _ = try await loader(transport).load(zswap)
            XCTFail("expected tooLarge")
        } catch OnchainAppError.tooLarge {
            // expected
        } catch { XCTFail("wrong error: \(error)") }
    }

    // MARK: - Approvals

    /// `async` on purpose: a `@MainActor` class released at the end of a
    /// synchronous test method trips the back-deployed isolated-deinit
    /// shim (malloc "pointer being freed was not allocated"); the async
    /// path releases it on the actor.
    func testApprovalsAreKeyedByExactBytesAndBounded() async {
        let approvals = OnchainApprovals()
        let trust = TestTrust.direct()
        let a = OnchainAppProvenance(app: zswap, networkName: "Ethereum", htmlHash: OnchainAppRef.htmlHash("a"), trust: trust)
        let b = OnchainAppProvenance(app: zswap, networkName: "Ethereum", htmlHash: OnchainAppRef.htmlHash("b"), trust: trust)
        XCTAssertFalse(approvals.isApproved(a))
        approvals.approve(a)
        XCTAssertTrue(approvals.isApproved(a))
        XCTAssertFalse(approvals.isApproved(b), "changed bytes warn again")
        // Same hash on another chain is a different app.
        let other = OnchainAppProvenance(app: OnchainAppRef(address: zswap.address, chainID: 100)!, networkName: "Gnosis", htmlHash: a.htmlHash, trust: trust)
        XCTAssertFalse(approvals.isApproved(other))
        for i in 0..<OnchainApprovals.capacity {
            approvals.approve(OnchainAppProvenance(app: zswap, networkName: "", htmlHash: "0x\(i)", trust: trust))
        }
        XCTAssertFalse(approvals.isApproved(a), "oldest entry evicted at capacity")
    }
}
