import XCTest
import web3
@testable import Freedom

@MainActor
final class ConsensusResolveTests: XCTestCase {
    private var settings: SettingsStore!
    private var pool: EthereumRPCPool!
    private var clock: MutableClock!

    private let alpha = URL(string: "https://alpha.example.com")!
    private let bravo = URL(string: "https://bravo.example.com")!
    private let charlie = URL(string: "https://charlie.example.com")!
    private let delta = URL(string: "https://delta.example.com")!
    private let echo = URL(string: "https://echo.example.com")!
    private let foxtrot = URL(string: "https://foxtrot.example.com")!

    private let sampleBytes = Data([0xAA, 0xBB])
    private let sampleResolver: EthereumAddress = "0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe"

    override func setUp() async throws {
        try await super.setUp()
        let defaults = UserDefaults(suiteName: "ConsensusResolveTests-\(UUID().uuidString)")!
        settings = SettingsStore(defaults: defaults)
        clock = MutableClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        pool = EthereumRPCPool(settings: settings, clock: { [unowned self] in self.clock.now })
    }

    // MARK: - Helpers

    private func makeAnchor(
        heads: [URL: UInt64],
        hashes: [URL: [UInt64: String]] = [:]
    ) -> AnchorCorroboration {
        AnchorCorroboration(
            pool: pool, settings: settings,
            clock: { [unowned self] in self.clock.now },
            fetchHead: { url, _, _ in
                guard let n = heads[url] else { throw URLError(.badServerResponse) }
                return n
            },
            fetchHash: { url, number, _ in
                guard let byNum = hashes[url], let h = byNum[number] else {
                    throw URLError(.badServerResponse)
                }
                return h
            }
        )
    }

    // MARK: - Scenarios

    func testVerifiedPathWhenMAgreement() async throws {
        settings.ensPublicRpcProviders = [alpha, bravo, charlie].map(\.absoluteString)
        let anchor = makeAnchor(
            heads: [alpha: 1000, bravo: 1000, charlie: 1000],
            hashes: [
                alpha: [992: "0xblock"], bravo: [992: "0xblock"], charlie: [992: "0xblock"],
            ]
        )
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: anchor,
            legRunner: makeLegRunner([
                alpha: .data(resolvedData: sampleBytes, resolverAddress: sampleResolver),
                bravo: .data(resolvedData: sampleBytes, resolverAddress: sampleResolver),
                charlie: .data(resolvedData: sampleBytes, resolverAddress: sampleResolver),
            ])
        )
        let result = try await resolver.consensusResolve(dnsEncodedName: Data(), callData: Data())
        guard case .data(let bytes, _, let trust) = result else {
            return XCTFail("expected .data, got \(result)")
        }
        XCTAssertEqual(bytes, sampleBytes)
        XCTAssertEqual(trust.level, .verified)
        XCTAssertEqual(trust.block.hash, "0xblock")
    }

    func testSingleSourceFallbackWhenKUnderpowered() async throws {
        // K<3 — corroborated path can't mint verified, so we degrade.
        settings.ensPublicRpcProviders = [alpha].map(\.absoluteString)
        settings.ensQuorumK = 2
        let anchor = makeAnchor(
            heads: [alpha: 1000],
            hashes: [alpha: [992: "0xblock"]]
        )
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: anchor,
            legRunner: makeLegRunner([
                alpha: .data(resolvedData: sampleBytes, resolverAddress: sampleResolver),
            ])
        )
        let result = try await resolver.consensusResolve(dnsEncodedName: Data(), callData: Data())
        guard case .data(_, _, let trust) = result else { return XCTFail() }
        XCTAssertEqual(trust.level, .unverified)
        XCTAssertEqual(trust.queried, ["alpha.example.com"])
    }

    func testSingleSourceFallbackWhenQuorumDisabled() async throws {
        settings.ensPublicRpcProviders = [alpha, bravo, charlie].map(\.absoluteString)
        settings.enableEnsQuorum = false
        // Provide anchor data for all three URLs — pool shuffles, so we
        // don't know which goes first into the single-source path.
        let anchor = makeAnchor(
            heads: [alpha: 1000, bravo: 1000, charlie: 1000],
            hashes: [
                alpha: [992: "0xblock"], bravo: [992: "0xblock"], charlie: [992: "0xblock"],
            ]
        )
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: anchor,
            legRunner: makeLegRunner([
                alpha: .data(resolvedData: sampleBytes, resolverAddress: sampleResolver),
                bravo: .data(resolvedData: sampleBytes, resolverAddress: sampleResolver),
                charlie: .data(resolvedData: sampleBytes, resolverAddress: sampleResolver),
            ])
        )
        let result = try await resolver.consensusResolve(dnsEncodedName: Data(), callData: Data())
        guard case .data(_, _, let trust) = result else { return XCTFail() }
        XCTAssertEqual(trust.level, .unverified)
    }

    func testHashDisagreementPropagates() async throws {
        settings.ensPublicRpcProviders = [alpha, bravo, charlie].map(\.absoluteString)
        // Three distinct hashes at the same block → anchor throws.
        let anchor = makeAnchor(
            heads: [alpha: 1000, bravo: 1000, charlie: 1000],
            hashes: [
                alpha: [992: "0xA"], bravo: [992: "0xB"], charlie: [992: "0xC"],
            ]
        )
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: anchor,
            legRunner: makeLegRunner([:])
        )
        do {
            _ = try await resolver.consensusResolve(dnsEncodedName: Data(), callData: Data())
            XCTFail("expected hashDisagreement to propagate")
        } catch AnchorCorroboration.AnchorError.hashDisagreement {
            // expected
        }
    }

    func testSecondWaveEscalationOnAllErrored() async throws {
        // First K=3 legs all error → second wave runs on the remaining
        // 3 URLs and agrees. Shuffle-agnostic: stateful legRunner errors
        // on the first 3 calls (regardless of URL), succeeds after.
        settings.ensPublicRpcProviders =
            [alpha, bravo, charlie, delta, echo, foxtrot].map(\.absoluteString)
        settings.ensQuorumK = 3
        settings.ensQuorumM = 2
        var heads: [URL: UInt64] = [:]
        var hashes: [URL: [UInt64: String]] = [:]
        for url in [alpha, bravo, charlie, delta, echo, foxtrot] {
            heads[url] = 1000
            hashes[url] = [992: "0xblock"]
        }
        let anchor = makeAnchor(heads: heads, hashes: hashes)

        let counter = ActorCallTracker()
        let bytes = sampleBytes
        let resolver_address = sampleResolver
        let legRunner: QuorumWave.LegRunner = { url, _, _, _, _, _ in
            await counter.increment()
            let n = await counter.value
            let kind: QuorumLeg.Outcome.Kind = n <= 3
                ? .error(URLError(.timedOut))
                : .data(resolvedData: bytes, resolverAddress: resolver_address)
            return QuorumLeg.Outcome(url: url, kind: kind)
        }
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: anchor,
            legRunner: legRunner
        )
        let result = try await resolver.consensusResolve(dnsEncodedName: Data(), callData: Data())
        guard case .data(_, _, let trust) = result else { return XCTFail() }
        XCTAssertEqual(trust.level, .verified)
    }

    func testConflictMapsToResult() async throws {
        settings.ensPublicRpcProviders = [alpha, bravo, charlie].map(\.absoluteString)
        let anchor = makeAnchor(
            heads: [alpha: 1000, bravo: 1000, charlie: 1000],
            hashes: [
                alpha: [992: "0xblock"], bravo: [992: "0xblock"], charlie: [992: "0xblock"],
            ]
        )
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: anchor,
            legRunner: makeLegRunner([
                alpha: .data(resolvedData: Data([0x01]), resolverAddress: sampleResolver),
                bravo: .data(resolvedData: Data([0x02]), resolverAddress: sampleResolver),
                charlie: .data(resolvedData: Data([0x03]), resolverAddress: sampleResolver),
            ])
        )
        let result = try await resolver.consensusResolve(dnsEncodedName: Data(), callData: Data())
        guard case .conflict(let groups, let trust) = result else { return XCTFail() }
        XCTAssertEqual(trust.level, .conflict)
        XCTAssertEqual(groups.count, 3)
    }

    // MARK: - Audit fixes (P1, P2a, P2b, P3)

    /// P2a: if the first wave all-errors and fewer than minQuorumProviders
    /// (3) providers remain, the second wave must NOT run — two agreeing
    /// providers would otherwise mint verified trust at K=2, violating the
    /// invariant that verified public quorum requires ≥3 independent legs.
    func testSecondWaveBlockedWhenTooFewRemain() async throws {
        settings.ensPublicRpcProviders = [alpha, bravo, charlie, delta, echo].map(\.absoluteString)
        settings.ensQuorumK = 3
        settings.ensQuorumM = 2
        var heads: [URL: UInt64] = [:]
        var hashes: [URL: [UInt64: String]] = [:]
        for url in [alpha, bravo, charlie, delta, echo] {
            heads[url] = 1000
            hashes[url] = [992: "0xblock"]
        }
        let anchor = makeAnchor(heads: heads, hashes: hashes)
        // First 3 legs error; the remaining 2 would otherwise agree and
        // mint verified data. Gate must prevent the second wave.
        let counter = ActorCallTracker()
        let bytes = sampleBytes
        let resolver_address = sampleResolver
        let legRunner: QuorumWave.LegRunner = { url, _, _, _, _, _ in
            await counter.increment()
            let n = await counter.value
            let kind: QuorumLeg.Outcome.Kind = n <= 3
                ? .error(URLError(.timedOut))
                : .data(resolvedData: bytes, resolverAddress: resolver_address)
            return QuorumLeg.Outcome(url: url, kind: kind)
        }
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: anchor,
            legRunner: legRunner
        )
        do {
            _ = try await resolver.consensusResolve(dnsEncodedName: Data(), callData: Data())
            XCTFail("expected .allErrored — second wave should not have minted verified")
        } catch ENSResolver.ConsensusError.allErrored {
            // expected
        }
        let calls = await counter.value
        XCTAssertEqual(calls, 3, "only the first wave should have run")
    }

    /// P1: custom-RPC toggle uses only the configured URL and tags trust
    /// as .userConfigured. Public pool is not consulted.
    func testCustomRpcFastPathSuccess() async throws {
        let custom = URL(string: "https://my-node.example.com")!
        settings.enableEnsCustomRpc = true
        settings.ensRpcUrl = custom.absoluteString
        // Public list still populated — we assert it's bypassed.
        settings.ensPublicRpcProviders = [alpha, bravo, charlie].map(\.absoluteString)
        let anchor = makeAnchor(
            heads: [custom: 1000, alpha: 9999, bravo: 9999, charlie: 9999],
            hashes: [custom: [992: "0xcustom"]]
        )
        let legRunner: QuorumWave.LegRunner = { [custom, sampleBytes, sampleResolver] url, _, _, _, _, _ in
            XCTAssertEqual(url, custom, "public pool was consulted despite custom RPC toggle")
            return QuorumLeg.Outcome(
                url: url,
                kind: .data(resolvedData: sampleBytes, resolverAddress: sampleResolver)
            )
        }
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: anchor, legRunner: legRunner
        )
        let result = try await resolver.consensusResolve(dnsEncodedName: Data(), callData: Data())
        guard case .data(_, _, let trust) = result else {
            return XCTFail("expected .data, got \(result)")
        }
        XCTAssertEqual(trust.level, .userConfigured)
        XCTAssertEqual(trust.queried, ["my-node.example.com"])
    }

    /// P1 fail-closed: invalid custom URL throws customRpcFailed, NOT
    /// allProvidersErrored. User chose custom RPC for privacy — silently
    /// falling back to public would defeat that intent.
    func testCustomRpcInvalidURLFailsClosed() async throws {
        settings.enableEnsCustomRpc = true
        settings.ensRpcUrl = ""  // empty → invalid
        settings.ensPublicRpcProviders = [alpha, bravo, charlie].map(\.absoluteString)
        let anchor = makeAnchor(heads: [:], hashes: [:])
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: anchor,
            legRunner: makeLegRunner([:])
        )
        do {
            _ = try await resolver.consensusResolve(dnsEncodedName: Data(), callData: Data())
            XCTFail("expected customRpcFailed")
        } catch ENSResolutionError.customRpcFailed {
            // expected
        }
    }

    /// P2b: .ccipDisabled buckets distinctly from .noContenthash so three
    /// agreeing legs produce a verified ccipDisabled outcome, not a
    /// verified no-content false negative.
    func testCcipDisabledBucketsDistinctly() async throws {
        settings.ensPublicRpcProviders = [alpha, bravo, charlie].map(\.absoluteString)
        let anchor = makeAnchor(
            heads: [alpha: 1000, bravo: 1000, charlie: 1000],
            hashes: [
                alpha: [992: "0xblock"], bravo: [992: "0xblock"], charlie: [992: "0xblock"],
            ]
        )
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: anchor,
            legRunner: makeLegRunner([
                alpha: .notFound(reason: .ccipDisabled),
                bravo: .notFound(reason: .ccipDisabled),
                charlie: .notFound(reason: .ccipDisabled),
            ])
        )
        let result = try await resolver.consensusResolve(dnsEncodedName: Data(), callData: Data())
        guard case .notFound(let reason, let trust) = result else {
            return XCTFail("expected .notFound, got \(result)")
        }
        XCTAssertEqual(reason, .ccipDisabled)
        XCTAssertEqual(trust.level, .verified)
    }

    /// P3: leg errors feed pool.markFailure so flaky providers quarantine
    /// across resolutions. Successes feed pool.markSuccess.
    func testErroredLegsFeedQuarantine() async throws {
        settings.ensPublicRpcProviders = [alpha, bravo, charlie].map(\.absoluteString)
        settings.ensQuorumK = 3
        settings.ensQuorumM = 2
        let anchor = makeAnchor(
            heads: [alpha: 1000, bravo: 1000, charlie: 1000],
            hashes: [
                alpha: [992: "0xblock"], bravo: [992: "0xblock"], charlie: [992: "0xblock"],
            ]
        )
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: anchor,
            legRunner: makeLegRunner([
                alpha: .error(URLError(.timedOut)),
                bravo: .data(resolvedData: sampleBytes, resolverAddress: sampleResolver),
                charlie: .error(URLError(.timedOut)),
            ])
        )
        _ = try? await resolver.consensusResolve(dnsEncodedName: Data(), callData: Data())
        let survivors = pool.availableProviders()
        XCTAssertTrue(survivors.contains(bravo), "bravo answered; should stay available")
        XCTAssertFalse(survivors.contains(alpha), "alpha errored; should be quarantined")
        XCTAssertFalse(survivors.contains(charlie), "charlie errored; should be quarantined")
    }

    func testAllErroredBothWavesThrows() async throws {
        settings.ensPublicRpcProviders = [alpha, bravo, charlie].map(\.absoluteString)
        settings.ensQuorumK = 3
        let anchor = makeAnchor(
            heads: [alpha: 1000, bravo: 1000, charlie: 1000],
            hashes: [
                alpha: [992: "0xblock"], bravo: [992: "0xblock"], charlie: [992: "0xblock"],
            ]
        )
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: anchor,
            legRunner: makeLegRunner([
                alpha: .error(URLError(.timedOut)),
                bravo: .error(URLError(.timedOut)),
                charlie: .error(URLError(.timedOut)),
            ])
        )
        do {
            _ = try await resolver.consensusResolve(dnsEncodedName: Data(), callData: Data())
            XCTFail("expected .allErrored")
        } catch ENSResolver.ConsensusError.allErrored {
            // expected
        }
    }
}
