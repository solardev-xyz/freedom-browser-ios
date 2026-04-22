import XCTest
import web3
@testable import Freedom

@MainActor
final class ENSResolverTests: XCTestCase {
    private var settings: SettingsStore!
    private var pool: EthereumRPCPool!
    private var clock: MutableClock!

    private let alpha = URL(string: "https://alpha.example.com")!
    private let bravo = URL(string: "https://bravo.example.com")!
    private let charlie = URL(string: "https://charlie.example.com")!

    private let sampleHashHex = "c0b683a3be2593bc7e22d252a371bac921bf47d11c3f3c1680ee60e6b8ccfcc8"
    private let resolverAddress: EthereumAddress = "0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe"

    override func setUp() async throws {
        try await super.setUp()
        let defaults = UserDefaults(suiteName: "ENSResolverTests-\(UUID().uuidString)")!
        settings = SettingsStore(defaults: defaults)
        settings.ensPublicRpcProviders = [alpha, bravo, charlie].map(\.absoluteString)
        clock = MutableClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        pool = EthereumRPCPool(settings: settings, clock: { [unowned self] in self.clock.now })
    }

    // MARK: - Helpers

    private func makeAnchor() -> AnchorCorroboration {
        AnchorCorroboration(
            pool: pool, settings: settings,
            clock: { [unowned self] in self.clock.now },
            fetchHead: { _, _, _ in 1000 },
            fetchHash: { _, _, _ in "0xblock" }
        )
    }

    private func bzzContenthash() -> Data {
        Data([0xe4, 0x01, 0x01, 0xfa, 0x01, 0x1b, 0x20]) + Data(hex: "0x\(sampleHashHex)")!
    }

    private func swarmOutcome(tracker: ActorCallTracker? = nil) -> QuorumWave.LegRunner {
        let encoded = abiEncodeBytes(bzzContenthash())
        let resolver = resolverAddress
        return { url, _, _, _, _, _ in
            if let tracker { await tracker.increment() }
            return QuorumLeg.Outcome(
                url: url,
                kind: .data(resolvedData: encoded, resolverAddress: resolver)
            )
        }
    }

    // MARK: - Scenarios

    func testResolveReturnsBzzURIOnVerifiedBytes() async throws {
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: swarmOutcome(),
            clock: { [unowned self] in self.clock.now }
        )
        let result = try await resolver.resolveContent("swarmit.eth")
        XCTAssertEqual(result.uri.absoluteString, "bzz://\(sampleHashHex)")
        XCTAssertEqual(result.codec, .bzz)
        XCTAssertEqual(result.trust.level, .verified)
    }

    func testInvalidNameThrows() async {
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: swarmOutcome(),
            clock: { [unowned self] in self.clock.now }
        )
        // Double-dot = empty middle label, forbidden by ENSIP-15.
        do {
            _ = try await resolver.resolveContent("foo..eth")
            XCTFail("expected invalidName for empty label")
        } catch ENSResolutionError.invalidName {
            // expected
        } catch {
            XCTFail("expected invalidName, got \(error)")
        }
    }

    func testCacheHitSkipsConsensus() async throws {
        let tracker = ActorCallTracker()
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: swarmOutcome(tracker: tracker),
            clock: { [unowned self] in self.clock.now }
        )
        _ = try await resolver.resolveContent("swarmit.eth")
        let firstCount = await tracker.value

        _ = try await resolver.resolveContent("swarmit.eth")
        let secondCount = await tracker.value

        XCTAssertEqual(secondCount, firstCount, "verified result cached for 15min")
    }

    func testCacheExpiresAfterVerifiedTTL() async throws {
        let tracker = ActorCallTracker()
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: swarmOutcome(tracker: tracker),
            clock: { [unowned self] in self.clock.now }
        )
        _ = try await resolver.resolveContent("swarmit.eth")
        let firstCount = await tracker.value

        clock.advance(by: 15 * 60 + 1)
        _ = try await resolver.resolveContent("swarmit.eth")
        let secondCount = await tracker.value

        XCTAssertGreaterThan(secondCount, firstCount)
    }

    func testInFlightDedupSharesTask() async throws {
        // Two concurrent resolves for the same name should share one
        // underlying consensus pass. Count how many times the leg runner
        // fires — with K=3 providers that's 3 per consensus call.
        let tracker = ActorCallTracker()
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: swarmOutcome(tracker: tracker),
            clock: { [unowned self] in self.clock.now }
        )

        async let a = resolver.resolveContent("swarmit.eth")
        async let b = resolver.resolveContent("swarmit.eth")
        _ = try await (a, b)

        let total = await tracker.value
        XCTAssertLessThanOrEqual(total, 3, "both calls shared one 3-leg wave")
    }

    func testEmptyContenthashMapsToNotFound() async {
        let emptyEncoded = abiEncodeBytes(Data())
        let addr = resolverAddress
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: { url, _, _, _, _, _ in
                QuorumLeg.Outcome(
                    url: url,
                    kind: .data(resolvedData: emptyEncoded, resolverAddress: addr)
                )
            },
            clock: { [unowned self] in self.clock.now }
        )
        do {
            _ = try await resolver.resolveContent("vacant.eth")
            XCTFail("expected notFound")
        } catch ENSResolutionError.notFound(let reason, _) {
            XCTAssertEqual(reason, .emptyContenthash)
        } catch {
            XCTFail("expected notFound, got \(error)")
        }
    }

    func testUnsupportedCodecMapsToError() async {
        // Bitcoin codec (0xe807) — we return unsupportedCodec rather than
        // pretending it's ipfs or failing as invalid.
        let payload = Data([0xe8, 0x07] + [UInt8](repeating: 0xab, count: 20))
        let encoded = abiEncodeBytes(payload)
        let addr = resolverAddress
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: { url, _, _, _, _, _ in
                QuorumLeg.Outcome(
                    url: url,
                    kind: .data(resolvedData: encoded, resolverAddress: addr)
                )
            },
            clock: { [unowned self] in self.clock.now }
        )
        do {
            _ = try await resolver.resolveContent("bitcoin.eth")
            XCTFail("expected unsupportedCodec")
        } catch ENSResolutionError.unsupportedCodec {
            // expected
        } catch {
            XCTFail("expected unsupportedCodec, got \(error)")
        }
    }

    func testNotFoundPropagates() async {
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: makeLegRunner([
                alpha: .notFound(reason: .noResolver),
                bravo: .notFound(reason: .noResolver),
                charlie: .notFound(reason: .noResolver),
            ]),
            clock: { [unowned self] in self.clock.now }
        )
        do {
            _ = try await resolver.resolveContent("unregistered.eth")
            XCTFail("expected notFound")
        } catch ENSResolutionError.notFound(let reason, let trust) {
            XCTAssertEqual(reason, .noResolver)
            XCTAssertEqual(trust.level, .verified)
        } catch {
            XCTFail("expected notFound, got \(error)")
        }
    }
}
