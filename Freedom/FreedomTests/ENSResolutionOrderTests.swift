import XCTest
import web3
@testable import Freedom

/// The ordered name-resolution policy (desktop "Resolution order"):
/// its one-time migration from the single-method picker, the legacy
/// shims, and the resolver walking enabled methods top to bottom with
/// Direct RPC as the user's endpoint or the public pool.
@MainActor
final class ENSResolutionOrderTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ENSOrder-\(UUID().uuidString)")!
    }

    // MARK: - Migration

    func testFreshInstallOrder() async {
        let store = SettingsStore(defaults: freshDefaults())
        XCTAssertEqual(store.ensResolutionOrder, [.myotis, .colibri, .quorum, .userConfigured])
        XCTAssertEqual(store.ensResolutionEnabled, [.myotis, .colibri, .quorum])
        XCTAssertEqual(store.ensEnabledResolutionMethods, [.myotis, .colibri, .quorum])
        XCTAssertTrue(store.ensPreferVerified)
        XCTAssertEqual(store.ensResolutionMethod, .colibri, "legacy read reports the first non-Myotis method")
    }

    func testLegacyQuorumPrimaryMigrates() async {
        let defaults = freshDefaults()
        defaults.set("quorum", forKey: "ensResolutionMethod")
        defaults.set(true, forKey: "ensResolutionMethodMigrated")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.ensEnabledResolutionMethods, [.myotis, .quorum])
    }

    func testLegacyQuorumDisabledMigratesToDirect() async {
        let defaults = freshDefaults()
        defaults.set("quorum", forKey: "ensResolutionMethod")
        defaults.set(true, forKey: "ensResolutionMethodMigrated")
        defaults.set(false, forKey: "enableEnsQuorum")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.ensEnabledResolutionMethods, [.myotis, .userConfigured], "the old single-source degrade is now Direct RPC")
    }

    func testLegacyCustomRPCMigrates() async {
        let defaults = freshDefaults()
        defaults.set("user-configured", forKey: "ensResolutionMethod")
        defaults.set(true, forKey: "ensResolutionMethodMigrated")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.ensEnabledResolutionMethods, [.myotis, .userConfigured], "fail-closed: no public method after the user's node")
        XCTAssertEqual(store.ensResolutionOrder, [.myotis, .userConfigured, .quorum, .colibri])
    }

    func testLegacyColibriWithoutFallbackMigrates() async {
        let defaults = freshDefaults()
        defaults.set(false, forKey: "ensFallbackToQuorum")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.ensEnabledResolutionMethods, [.myotis, .colibri])
    }

    func testMigrationRunsOnceAndPersistsEdits() async {
        let defaults = freshDefaults()
        let first = SettingsStore(defaults: defaults)
        first.setResolutionOrder([.quorum, .myotis])
        first.setResolutionMethod(.colibri, enabled: false)
        first.ensPreferVerified = false
        let relaunch = SettingsStore(defaults: defaults)
        XCTAssertEqual(relaunch.ensResolutionOrder, [.quorum, .myotis, .colibri, .userConfigured])
        XCTAssertEqual(relaunch.ensResolutionEnabled, [.myotis, .quorum])
        XCTAssertFalse(relaunch.ensPreferVerified)
    }

    func testOrderIsNormalized() async {
        let store = SettingsStore(defaults: freshDefaults())
        store.setResolutionOrder([.userConfigured, .userConfigured, .direct])
        XCTAssertEqual(store.ensResolutionOrder, [.userConfigured, .myotis, .colibri, .quorum])
    }

    func testLegacyShimsRewriteTheOrder() async {
        let store = SettingsStore(defaults: freshDefaults())
        store.ensResolutionMethod = .userConfigured
        XCTAssertEqual(store.ensEnabledResolutionMethods, [.myotis, .userConfigured])
        store.enableEnsQuorum = true
        XCTAssertEqual(store.ensEnabledResolutionMethods, [.myotis, .userConfigured, .quorum])
        store.enableEnsQuorum = false
        XCTAssertEqual(store.ensEnabledResolutionMethods, [.myotis, .userConfigured])
        store.ensResolutionMethod = .colibri
        XCTAssertEqual(store.ensEnabledResolutionMethods, [.myotis, .colibri, .quorum])
        store.ensFallbackToQuorum = false
        XCTAssertEqual(store.ensEnabledResolutionMethods, [.myotis, .colibri])
    }

    // MARK: - Resolver walk

    private let alpha = URL(string: "https://alpha.example.com")!
    private let bravo = URL(string: "https://bravo.example.com")!
    private let charlie = URL(string: "https://charlie.example.com")!
    private let sampleBytes = Data([0xe3, 0x01, 0x01, 0x70, 0x12, 0x20] + [UInt8](repeating: 0xab, count: 32))
    private let sampleResolver = EthereumAddress("0x231b0Ee14048e9dCcD1d247744d114a4EB5E8E63")

    private func makeResolver(
        settings: SettingsStore,
        legs: [URL: QuorumLeg.Outcome.Kind]
    ) -> ENSResolver {
        let pool = mainnetPool(settings: settings)
        let anchor = AnchorCorroboration(
            pool: pool, settings: settings,
            fetchHead: { _, _, _ in 1000 },
            fetchHash: { _, _, _ in "0xblock" }
        )
        return ENSResolver(pool: pool, settings: settings, anchor: anchor, legRunner: makeLegRunner(legs))
    }

    func testDirectRPCUsesThePublicPoolWithoutACustomEndpoint() async throws {
        let settings = SettingsStore(defaults: freshDefaults())
        settings.ensPublicRpcProviders = [alpha, bravo].map(\.absoluteString)
        settings.setResolutionOrder([.userConfigured, .quorum])
        settings.ensResolutionEnabled = [.userConfigured]
        settings.ensPreferVerified = false
        let resolver = makeResolver(settings: settings, legs: [
            alpha: .data(resolvedData: sampleBytes, resolverAddress: sampleResolver),
        ])
        let result = try await resolver.consensusResolve(dnsEncodedName: Data(), callData: Data())
        guard case .data(_, _, let trust) = result else { return XCTFail("expected data") }
        XCTAssertEqual(trust.level, .unverified)
        XCTAssertEqual(trust.queried, ["alpha.example.com"])
    }

    func testDirectRPCPrefersTheUsersEndpoint() async throws {
        let settings = SettingsStore(defaults: freshDefaults())
        settings.ensPublicRpcProviders = [alpha].map(\.absoluteString)
        settings.ensRpcUrl = charlie.absoluteString
        settings.ensResolutionEnabled = [.userConfigured]
        let resolver = makeResolver(settings: settings, legs: [
            charlie: .data(resolvedData: sampleBytes, resolverAddress: sampleResolver),
            alpha: .data(resolvedData: Data([0x00]), resolverAddress: sampleResolver),
        ])
        let result = try await resolver.consensusResolve(dnsEncodedName: Data(), callData: Data())
        guard case .data(_, _, let trust) = result else { return XCTFail("expected data") }
        XCTAssertEqual(trust.level, .userConfigured)
        XCTAssertEqual(trust.queried, ["charlie.example.com"])
    }

    func testPreferVerifiedHoldsAnUnverifiedAnswerWhileQuorumTries() async throws {
        let settings = SettingsStore(defaults: freshDefaults())
        settings.ensPublicRpcProviders = [alpha, bravo, charlie].map(\.absoluteString)
        settings.setResolutionOrder([.userConfigured, .quorum])
        settings.ensResolutionEnabled = [.userConfigured, .quorum]
        settings.ensPreferVerified = true
        let resolver = makeResolver(settings: settings, legs: [
            alpha: .data(resolvedData: sampleBytes, resolverAddress: sampleResolver),
            bravo: .data(resolvedData: sampleBytes, resolverAddress: sampleResolver),
            charlie: .data(resolvedData: sampleBytes, resolverAddress: sampleResolver),
        ])
        let result = try await resolver.consensusResolve(dnsEncodedName: Data(), callData: Data())
        guard case .data(_, _, let trust) = result else { return XCTFail("expected data") }
        XCTAssertEqual(trust.level, .verified, "the quorum's verified answer wins over the held direct one")
        XCTAssertEqual(trust.method, .quorum)
    }

    func testHeldUnverifiedAnswerIsReturnedWhenNothingVerifies() async throws {
        let settings = SettingsStore(defaults: freshDefaults())
        // Two providers: direct answers, quorum is infeasible (needs 3).
        settings.ensPublicRpcProviders = [alpha, bravo].map(\.absoluteString)
        settings.setResolutionOrder([.userConfigured, .quorum])
        settings.ensResolutionEnabled = [.userConfigured, .quorum]
        let resolver = makeResolver(settings: settings, legs: [
            alpha: .data(resolvedData: sampleBytes, resolverAddress: sampleResolver),
        ])
        let result = try await resolver.consensusResolve(dnsEncodedName: Data(), callData: Data())
        XCTAssertEqual(result.trustLevel, .unverified)
    }

    func testDisabledDirectMeansAnInfeasibleQuorumFails() async throws {
        let settings = SettingsStore(defaults: freshDefaults())
        settings.ensPublicRpcProviders = [alpha].map(\.absoluteString)
        settings.ensResolutionEnabled = [.quorum]
        let resolver = makeResolver(settings: settings, legs: [
            alpha: .data(resolvedData: sampleBytes, resolverAddress: sampleResolver),
        ])
        do {
            _ = try await resolver.consensusResolve(dnsEncodedName: Data(), callData: Data())
            XCTFail("expected failure")
        } catch is ENSResolver.TierUnavailable {
            // the last method's own failure surfaces; callers map it to allProvidersErrored
        }
    }

    func testEmptyOrderFailsCleanly() async throws {
        let settings = SettingsStore(defaults: freshDefaults())
        settings.ensResolutionEnabled = []
        let resolver = makeResolver(settings: settings, legs: [:])
        do {
            _ = try await resolver.consensusResolve(dnsEncodedName: Data(), callData: Data())
            XCTFail("expected failure")
        } catch ENSResolutionError.allProvidersErrored {
            // expected
        }
    }
}
