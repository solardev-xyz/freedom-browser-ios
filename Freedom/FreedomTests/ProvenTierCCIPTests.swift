import XCTest
import web3
import MyotisKit
@testable import Freedom

/// EIP-3668 on the proven tiers (desktop PR #352 parity): an
/// `OffchainLookup` revert from the Universal Resolver is driven through
/// `CCIPResolver` with the callback re-executed by the same verifier, so
/// the answer keeps the tier's trust instead of falling through to the
/// quorum path. Exercised through the Myotis closure seam; the Colibri
/// branch shares `provenCCIP` and `provenReverseRevert` verbatim.
@MainActor
final class ProvenTierCCIPTests: XCTestCase {
    private var settings: SettingsStore!
    private var pool: EthereumRPCPool!
    private var clock: MutableClock!

    private let alpha = URL(string: "https://alpha.example.com")!
    private let universalResolver = UniversalResolverABI.address
    private let resolverAddress: EthereumAddress = "0x231b0Ee14048e9dCcD1d247744d114a4EB5E8E63"
    private let gatewayPayload = Data([0x01, 0x02, 0x03, 0x04])
    private let extraData = Data([0xe1, 0xe2])
    private let callbackSelector = Data([0xde, 0xad, 0xbe, 0xef])
    private let recordBytes = Data([0xAA, 0xBB, 0xCC])

    override func setUp() async throws {
        try await super.setUp()
        let defaults = UserDefaults(suiteName: "ProvenTierCCIPTests-\(UUID().uuidString)")!
        settings = SettingsStore(defaults: defaults)
        settings.ensResolutionMethod = .quorum
        settings.enableEnsQuorum = false
        settings.ensPublicRpcProviders = [alpha.absoluteString]
        settings.enableCcipRead = true
        clock = MutableClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        pool = mainnetPool(settings: settings, clock: { [unowned self] in self.clock.now })
    }

    private func makeAnchor() -> AnchorCorroboration {
        AnchorCorroboration(
            pool: pool, settings: settings,
            clock: { [unowned self] in self.clock.now },
            fetchHead: { _, _, _ in 1000 },
            fetchHash: { _, _, _ in "0xblock" }
        )
    }

    /// Resolver whose quorum fallback answers with distinct bytes, so a
    /// fall-through is observable.
    private func resolver(
        myotis: MyotisENSClient,
        http: @escaping CCIPResolver.HTTPClient
    ) -> ENSResolver {
        ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: makeLegRunner([
                alpha: .data(resolvedData: Data([0xFB]), resolverAddress: resolverAddress),
            ]),
            reverseCCIPHTTP: http,
            myotis: myotis
        )
    }

    private func offchainLookupHex(sender: EthereumAddress) -> String {
        encodeOffchainLookupRevert(
            address: sender,
            urls: ["https://gateway.example/{sender}/{data}.json"],
            callbackFunction: callbackSelector,
            extraData: extraData
        ).web3.hexString
    }

    /// UR `resolve()` / `resolveCallback()` return: `(bytes, address)`.
    private func resolveResponseHex(_ data: Data) -> String {
        let encoder = ABIFunctionEncoder("_")
        try! encoder.encode(data)
        try! encoder.encode(resolverAddress)
        return Data(try! encoder.encoded().dropFirst(4)).web3.hexString
    }

    private func gatewayHTTP() -> CCIPResolver.HTTPClient {
        let body = try! JSONSerialization.data(withJSONObject: ["data": gatewayPayload.web3.hexString])
        return { _, _ in CCIPResolver.GatewayResponse(status: 200, body: body) }
    }

    // MARK: - Forward

    func testOffchainLookupIsDrivenThroughTheProvenTier() async throws {
        let calls = CallLog()
        let lookup = offchainLookupHex(sender: universalResolver)
        let answer = resolveResponseHex(recordBytes)
        let client = MyotisENSClient(
            availability: { true },
            ethCall: { to, data in
                let n = await calls.record(to: to, data: data)
                return n == 1 ? .revert(dataHex: lookup) : .ok(resultHex: answer)
            }
        )
        let result = try await resolver(myotis: client, http: gatewayHTTP()).consensusResolve(
            dnsEncodedName: Data([0x01]), callData: Data([0x02])
        )
        guard case .data(let bytes, let resolver, let trust) = result else {
            return XCTFail("expected .data, got \(result)")
        }
        XCTAssertEqual(bytes, recordBytes)
        XCTAssertEqual(resolver, resolverAddress)
        XCTAssertEqual(trust.method, .myotis, "CCIP answer must keep the proven tier's trust")
        XCTAssertEqual(trust.level, .verified)

        let recorded = await calls.entries
        XCTAssertEqual(recorded.count, 2, "resolve() then one callback")
        XCTAssertEqual(recorded[1].to.lowercased(), universalResolver.asString().lowercased())
        let callback = try XCTUnwrap(recorded[1].data.web3.hexData)
        XCTAssertEqual(callback.prefix(4), callbackSelector)
        let decoded = try ABIDecoder.decodeData(
            Data(callback.dropFirst(4)).web3.hexString, types: [Data.self, Data.self]
        )
        XCTAssertEqual(try decoded[0].decoded() as Data, gatewayPayload)
        XCTAssertEqual(try decoded[1].decoded() as Data, extraData)
    }

    /// A forged sender must neither reach a gateway nor mint a proven
    /// answer: the tier falls through to the quorum fallback.
    func testForgedSenderFallsThroughWithoutGatewayRequest() async throws {
        let lookup = offchainLookupHex(sender: resolverAddress)
        let client = MyotisENSClient(
            availability: { true },
            ethCall: { _, _ in .revert(dataHex: lookup) }
        )
        let gatewayHits = ActorCallTracker()
        let http: CCIPResolver.HTTPClient = { _, _ in
            await gatewayHits.increment()
            return CCIPResolver.GatewayResponse(status: 200, body: Data())
        }
        let result = try await resolver(myotis: client, http: http).consensusResolve(
            dnsEncodedName: Data([0x01]), callData: Data([0x02])
        )
        guard case .data(let bytes, _, let trust) = result else {
            return XCTFail("expected .data, got \(result)")
        }
        XCTAssertEqual(bytes, Data([0xFB]), "quorum fallback must have answered")
        XCTAssertNotEqual(trust.method, .myotis)
        let hits = await gatewayHits.value
        XCTAssertEqual(hits, 0)
    }

    /// Gateway outage is not a verified negative: fall through, don't
    /// cache "no record" under proven trust.
    func testGatewayFailureFallsThrough() async throws {
        let lookup = offchainLookupHex(sender: universalResolver)
        let client = MyotisENSClient(
            availability: { true },
            ethCall: { _, _ in .revert(dataHex: lookup) }
        )
        let http: CCIPResolver.HTTPClient = { _, _ in
            CCIPResolver.GatewayResponse(status: 503, body: Data())
        }
        let result = try await resolver(myotis: client, http: http).consensusResolve(
            dnsEncodedName: Data([0x01]), callData: Data([0x02])
        )
        guard case .data(let bytes, _, let trust) = result else {
            return XCTFail("expected .data, got \(result)")
        }
        XCTAssertEqual(bytes, Data([0xFB]))
        XCTAssertNotEqual(trust.method, .myotis)
    }

    /// A callback that reverts means the resolver rejected the gateway
    /// data under proof — also not a negative. Fall through.
    func testCallbackRevertFallsThrough() async throws {
        let calls = ActorCallTracker()
        let lookup = offchainLookupHex(sender: universalResolver)
        let client = MyotisENSClient(
            availability: { true },
            ethCall: { _, _ in
                await calls.increment()
                return .revert(dataHex: await calls.value == 1 ? lookup : "0x08c379a0")
            }
        )
        let result = try await resolver(myotis: client, http: gatewayHTTP()).consensusResolve(
            dnsEncodedName: Data([0x01]), callData: Data([0x02])
        )
        guard case .data(let bytes, _, _) = result else {
            return XCTFail("expected .data, got \(result)")
        }
        XCTAssertEqual(bytes, Data([0xFB]))
    }

    /// CCIP-Read disabled: a proven `.ccipDisabled` negative, same reason
    /// the quorum legs report, so the UI can explain the setting.
    func testCcipDisabledYieldsProvenNegative() async throws {
        settings.enableCcipRead = false
        let lookup = offchainLookupHex(sender: universalResolver)
        let client = MyotisENSClient(
            availability: { true },
            ethCall: { _, _ in .revert(dataHex: lookup) }
        )
        let result = try await resolver(myotis: client, http: gatewayHTTP()).consensusResolve(
            dnsEncodedName: Data([0x01]), callData: Data([0x02])
        )
        guard case .notFound(let reason, let trust) = result else {
            return XCTFail("expected .notFound, got \(result)")
        }
        XCTAssertEqual(reason, .ccipDisabled)
        XCTAssertEqual(trust.method, .myotis)
    }

    // MARK: - Revert classification on the tier

    /// `ResolverNotFound` is the UR proving no resolver serves the name:
    /// a verified `.noResolver` under the tier's trust.
    func testResolverNotFoundIsAProvenNegative() async throws {
        let client = MyotisENSClient(
            availability: { true },
            ethCall: { _, _ in .revert(dataHex: "0x77209fe8" + String(repeating: "0", count: 64)) }
        )
        let result = try await resolver(myotis: client, http: gatewayHTTP()).consensusResolve(
            dnsEncodedName: Data([0x01]), callData: Data([0x02])
        )
        guard case .notFound(let reason, let trust) = result else {
            return XCTFail("expected .notFound, got \(result)")
        }
        XCTAssertEqual(reason, .noResolver)
        XCTAssertEqual(trust.method, .myotis)
    }

    /// Any other revert is a proved execution failure (DNSSEC
    /// `SignatureNotValidYet`, a custom resolver error) and must let the
    /// next method try rather than be cached as "no record".
    func testResolverExecutionErrorFallsThrough() async throws {
        let client = MyotisENSClient(
            availability: { true },
            ethCall: { _, _ in .revert(dataHex: "0x08c379a0" + String(repeating: "ab", count: 64)) }
        )
        let result = try await resolver(myotis: client, http: gatewayHTTP()).consensusResolve(
            dnsEncodedName: Data([0x01]), callData: Data([0x02])
        )
        guard case .data(let bytes, _, let trust) = result else {
            return XCTFail("expected quorum fallback .data, got \(result)")
        }
        XCTAssertEqual(bytes, Data([0xFB]))
        XCTAssertNotEqual(trust.method, .myotis)
    }

    func testReverseExecutionErrorFallsThroughToNextTier() async throws {
        // The Myotis tier fails with an execution error; the quorum
        // reverse transport then answers. A `.none` from Myotis would
        // have been cached instead.
        let client = MyotisENSClient(
            availability: { true },
            ethCall: { _, _ in .revert(dataHex: "0x08c379a0" + String(repeating: "ab", count: 64)) }
        )
        let encoder = ABIFunctionEncoder("_")
        try encoder.encode("fallback.eth")
        try encoder.encode(resolverAddress)
        try encoder.encode(resolverAddress)
        let tuple = Data(try encoder.encoded().dropFirst(4)).web3.hexString
        let envelope = try rpcResult(tuple)
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            reverseTransport: { _, _, _ in envelope },
            myotis: client
        )
        let result = try await resolver.reverseResolve(address: "0xd8da6bf26964af9d7eed9e03e53415d37aa96045")
        XCTAssertEqual(result, .verified(name: "fallback.eth"))
    }

    // MARK: - Reverse

    func testReversePrimaryBehindGatewayResolvesOnTheProvenTier() async throws {
        let calls = ActorCallTracker()
        let lookup = offchainLookupHex(sender: universalResolver)
        let encoder = ABIFunctionEncoder("_")
        try encoder.encode("avsa.eth")
        try encoder.encode(resolverAddress)
        try encoder.encode(resolverAddress)
        let tuple = Data(try encoder.encoded().dropFirst(4)).web3.hexString
        let client = MyotisENSClient(
            availability: { true },
            ethCall: { _, _ in
                await calls.increment()
                return await calls.value == 1 ? .revert(dataHex: lookup) : .ok(resultHex: tuple)
            }
        )
        let resolver = resolver(myotis: client, http: gatewayHTTP())
        let result = try await resolver.reverseResolve(address: "0xd8da6bf26964af9d7eed9e03e53415d37aa96045")
        XCTAssertEqual(result, .verified(name: "avsa.eth"))
        let n = await calls.value
        XCTAssertEqual(n, 2)
    }
}

private actor CallLog {
    struct Entry { let to: String; let data: String }
    private(set) var entries: [Entry] = []
    func record(to: String, data: String) -> Int {
        entries.append(Entry(to: to, data: data))
        return entries.count
    }
}
