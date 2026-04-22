import XCTest
@testable import Freedom

@MainActor
final class EthereumRPCPoolTests: XCTestCase {
    private var settings: SettingsStore!
    private var clock: MutableClock!
    private var pool: EthereumRPCPool!

    override func setUp() async throws {
        try await super.setUp()
        let defaults = UserDefaults(suiteName: "EthereumRPCPoolTests-\(UUID().uuidString)")!
        settings = SettingsStore(defaults: defaults)
        clock = MutableClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        pool = EthereumRPCPool(settings: settings, clock: { [unowned self] in self.clock.now })
    }

    func testReturnsShuffledSettingsList() {
        settings.ensPublicRpcProviders = [
            "https://a.example.com",
            "https://b.example.com",
            "https://c.example.com",
        ]
        let got = Set(pool.availableProviders().map(\.absoluteString))
        XCTAssertEqual(got, Set(settings.ensPublicRpcProviders))
    }

    func testFallsBackToDefaultsWhenSettingsEmpty() {
        settings.ensPublicRpcProviders = []
        let got = pool.availableProviders()
        XCTAssertFalse(got.isEmpty)
        XCTAssertEqual(got.count, SettingsStore.defaultPublicRpcProviders.count)
    }

    func testFallsBackToDefaultsWhenAllSettingsAreWhitespace() {
        // User who saves only empty/whitespace entries shouldn't silently
        // break ENS resolution — we fall through to the hardcoded defaults.
        settings.ensPublicRpcProviders = ["", "   ", "\t\n"]
        let got = pool.availableProviders()
        XCTAssertEqual(got.count, SettingsStore.defaultPublicRpcProviders.count)
    }

    func testDeduplicatesCaseInsensitive() {
        settings.ensPublicRpcProviders = [
            "https://Eth.Example.com",
            "https://eth.example.com",
            "  https://eth.example.com  ",
        ]
        XCTAssertEqual(pool.availableProviders().count, 1)
    }

    func testMarkFailureQuarantines() {
        settings.ensPublicRpcProviders = ["https://a.example.com", "https://b.example.com"]
        let all = pool.availableProviders()
        pool.markFailure(all[0])
        let after = pool.availableProviders()
        XCTAssertEqual(after, [all[1]])
    }

    func testExpiredQuarantineReSurfaces() {
        settings.ensPublicRpcProviders = ["https://a.example.com"]
        let url = pool.availableProviders()[0]
        pool.markFailure(url)
        XCTAssertTrue(pool.availableProviders().isEmpty)

        // Base cooldown is 60s; advance past it.
        clock.advance(by: 61)
        XCTAssertEqual(pool.availableProviders(), [url])
    }

    func testBackoffGrowsExponentiallyAndCaps() {
        settings.ensPublicRpcProviders = ["https://a.example.com"]
        let url = pool.availableProviders()[0]

        // 1 failure → 60s
        pool.markFailure(url)
        clock.advance(by: 59)
        XCTAssertTrue(pool.availableProviders().isEmpty)
        clock.advance(by: 2)
        XCTAssertEqual(pool.availableProviders(), [url])

        // Stack failures. 10 more → 60 × 2^10 = 61 440s, capped at 600s (10 min).
        for _ in 0..<11 { pool.markFailure(url) }
        clock.advance(by: 599)
        XCTAssertTrue(pool.availableProviders().isEmpty, "should still be quarantined before 10-min cap")
        clock.advance(by: 2)
        XCTAssertEqual(pool.availableProviders(), [url], "should expire at cap, not longer")
    }

    func testMarkSuccessClearsQuarantine() {
        settings.ensPublicRpcProviders = ["https://a.example.com"]
        let url = pool.availableProviders()[0]
        pool.markFailure(url)
        pool.markFailure(url)
        pool.markSuccess(url)
        XCTAssertEqual(pool.availableProviders(), [url])
    }

    func testInvalidateClearsQuarantine() {
        settings.ensPublicRpcProviders = ["https://a.example.com"]
        let url = pool.availableProviders()[0]
        pool.markFailure(url)
        pool.invalidate()
        XCTAssertEqual(pool.availableProviders(), [url])
    }

    func testRemovingProviderFromSettingsDropsItsQuarantineEntry() {
        settings.ensPublicRpcProviders = ["https://a.example.com", "https://b.example.com"]
        let first = pool.availableProviders().first { $0.absoluteString == "https://a.example.com" }!
        pool.markFailure(first)

        // User edits settings to re-add later — quarantine shouldn't stick.
        settings.ensPublicRpcProviders = ["https://b.example.com"]
        _ = pool.availableProviders()  // triggers refresh + orphan cleanup
        settings.ensPublicRpcProviders = ["https://a.example.com", "https://b.example.com"]
        let now = Set(pool.availableProviders().map(\.absoluteString))
        XCTAssertEqual(now, ["https://a.example.com", "https://b.example.com"])
    }
}

private final class MutableClock {
    var now: Date
    init(now: Date) { self.now = now }
    func advance(by interval: TimeInterval) { now.addTimeInterval(interval) }
}
