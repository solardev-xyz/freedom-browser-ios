import XCTest
import web3
import MyotisKit
@testable import Freedom

/// The Myotis tier's contract inside `ENSResolver.consensusResolve`:
/// answers first when available, mints `.myotis` verified trust, and
/// falls through unconditionally on unavailability/failure. Uses the
/// client's closure seam — no live engine.
@MainActor
final class MyotisResolverTierTests: XCTestCase {
    private var settings: SettingsStore!
    private var pool: EthereumRPCPool!
    private var clock: MutableClock!

    private let alpha = URL(string: "https://alpha.example.com")!
    private let sampleBytes = Data([0xAA, 0xBB])
    private let sampleResolver: EthereumAddress = "0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe"

    override func setUp() async throws {
        try await super.setUp()
        let defaults = UserDefaults(suiteName: "MyotisResolverTierTests-\(UUID().uuidString)")!
        settings = SettingsStore(defaults: defaults)
        clock = MutableClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        pool = mainnetPool(settings: settings, clock: { [unowned self] in self.clock.now })
    }

    /// A ready client answering every eth_call with `outcome`.
    private func client(
        available: Bool = true,
        outcome: MyotisCallOutcome
    ) -> MyotisENSClient {
        MyotisENSClient(
            availability: { available },
            verifiedBlock: { 25_760_849 },
            ethCall: { _, _ in outcome }
        )
    }

    /// Resolver with the Myotis tier plus a single-provider quorum
    /// fallback that returns `fallbackBytes` — distinct bytes prove
    /// which tier answered.
    private func makeAnchor() -> AnchorCorroboration {
        AnchorCorroboration(
            pool: pool, settings: settings,
            clock: { [unowned self] in self.clock.now },
            fetchHead: { _, _, _ in 1000 },
            fetchHash: { _, _, _ in "0xblock" }
        )
    }

    private func resolver(
        myotis: MyotisENSClient?,
        fallbackBytes: Data = Data([0xFB])
    ) -> ENSResolver {
        settings.ensResolutionMethod = .quorum
        settings.enableEnsQuorum = false // degrade path: single-source
        settings.ensPublicRpcProviders = [alpha.absoluteString]
        return ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: makeLegRunner([
                alpha: .data(resolvedData: fallbackBytes, resolverAddress: sampleResolver),
            ]),
            myotis: myotis
        )
    }

    // MARK: - WNS/GNS (NameNFT) path: raw proven call, easiest to pin

    func testAvailableMyotisAnswersFirstWithP2PTrust() async throws {
        let resolver = resolver(
            myotis: client(outcome: .ok(resultHex: sampleBytes.web3.hexString))
        )
        let result = try await resolver.consensusResolve(
            dnsEncodedName: Data(), callData: Data([0x01]), system: .wns
        )
        guard case .data(let bytes, _, let trust) = result else {
            return XCTFail("expected .data, got \(result)")
        }
        XCTAssertEqual(bytes, sampleBytes)
        XCTAssertEqual(trust.level, .verified)
        XCTAssertEqual(trust.method, .myotis)
        XCTAssertEqual(trust.block.number, 25_760_849)
        XCTAssertEqual(trust.queried, [ENSResolver.myotisProviderLabel])
        XCTAssertEqual(trust.k, 1)
        XCTAssertEqual(trust.m, 1)
    }

    func testUnavailableClientSkipsTierEntirely() async throws {
        var called = false
        let myotis = MyotisENSClient(
            availability: { false },
            ethCall: { _, _ in
                called = true
                return .ok(resultHex: "0x00")
            }
        )
        let result = try await resolver(myotis: myotis).consensusResolve(
            dnsEncodedName: Data(), callData: Data([0x01]), system: .wns
        )
        guard case .data(let bytes, _, let trust) = result else {
            return XCTFail("expected .data, got \(result)")
        }
        XCTAssertFalse(called, "not-ready client must not be called at all")
        XCTAssertEqual(bytes, Data([0xFB]), "fallback tier must have answered")
        XCTAssertNotEqual(trust.method, .myotis)
    }

    func testUnavailableOutcomeFallsThrough() async throws {
        let resolver = resolver(
            myotis: client(outcome: .unavailable(reason: "no snap peer available"))
        )
        let result = try await resolver.consensusResolve(
            dnsEncodedName: Data(), callData: Data([0x01]), system: .wns
        )
        guard case .data(let bytes, _, let trust) = result else {
            return XCTFail("expected .data, got \(result)")
        }
        XCTAssertEqual(bytes, Data([0xFB]))
        XCTAssertNotEqual(trust.method, .myotis)
    }

    func testEngineErrorFallsThrough() async throws {
        let resolver = resolver(
            myotis: client(outcome: .error("state unavailable for 0xabc"))
        )
        let result = try await resolver.consensusResolve(
            dnsEncodedName: Data(), callData: Data([0x01]), system: .wns
        )
        guard case .data(let bytes, _, _) = result else {
            return XCTFail("expected .data, got \(result)")
        }
        XCTAssertEqual(bytes, Data([0xFB]))
    }

    /// A NameNFT revert falls through (parity with the Colibri tier,
    /// whose NameNFT reverts propagate to the fallback path — the
    /// registries have no UR error vocabulary to decode).
    func testNameNftRevertFallsThrough() async throws {
        let resolver = resolver(
            myotis: client(outcome: .revert(dataHex: "0x08c379a0"))
        )
        let result = try await resolver.consensusResolve(
            dnsEncodedName: Data(), callData: Data([0x01]), system: .wns
        )
        guard case .data(let bytes, _, _) = result else {
            return XCTFail("expected .data, got \(result)")
        }
        XCTAssertEqual(bytes, Data([0xFB]))
    }

    // MARK: - Settings / cache plumbing

    func testMyotisNodeEnabledDefaultsOn() {
        // Reuses the instance property rather than a synchronously
        // dropped temporary: an immediately-deinited SettingsStore trips
        // the known layout-dependent heap-corruption flake (see
        // TransactionServiceTests note) deterministically here.
        let defaults = UserDefaults(suiteName: "MyotisDefaults-\(UUID().uuidString)")!
        settings = SettingsStore(defaults: defaults)
        XCTAssertTrue(settings.myotisNodeEnabled)
    }

    func testMethodPickerExcludesMyotis() {
        XCTAssertFalse(ENSResolutionMethod.selectableCases.contains(.myotis))
        XCTAssertEqual(
            Set(ENSResolutionMethod.selectableCases),
            Set([.colibri, .quorum, .userConfigured])
        )
    }

    func testSweepResultCachesEnablesImmediateTakeover() async throws {
        // Prime the content cache through the fallback tier while the
        // client is not ready, flip it ready, and prove: (a) without a
        // sweep the cached lower-tier answer keeps being served; (b) the
        // sweep drops it so the very next resolution is P2P-verified.
        let sampleHashHex = "c0b683a3be2593bc7e22d252a371bac921bf47d11c3f3c1680ee60e6b8ccfcc8"
        let bzzContenthash = Data([0xe4, 0x01, 0x01, 0xfa, 0x01, 0x1b, 0x20])
            + Data(hex: "0x\(sampleHashHex)")!
        let encoded = abiEncodeBytes(bzzContenthash)

        var available = false
        let myotis = MyotisENSClient(
            availability: { available },
            ethCall: { _, _ in .ok(resultHex: encoded.web3.hexString) }
        )
        settings.ensResolutionMethod = .quorum
        settings.enableEnsQuorum = false
        settings.ensPublicRpcProviders = [alpha.absoluteString]
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: makeLegRunner([
                alpha: .data(resolvedData: encoded, resolverAddress: sampleResolver),
            ]),
            clock: { [unowned self] in self.clock.now },
            myotis: myotis
        )

        let first = try await resolver.resolveContent("swarmit.wei")
        XCTAssertNotEqual(first.trust.method, .myotis)

        available = true
        let cached = try await resolver.resolveContent("swarmit.wei")
        XCTAssertNotEqual(
            cached.trust.method, .myotis,
            "within TTL and without a sweep, the cached answer is served"
        )

        resolver.sweepResultCaches()
        let swept = try await resolver.resolveContent("swarmit.wei")
        XCTAssertEqual(swept.trust.method, .myotis)
        XCTAssertEqual(swept.contentRef, sampleHashHex)
    }
}
