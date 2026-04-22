import XCTest
@testable import Freedom

@MainActor
final class AnchorCorroborationTests: XCTestCase {
    private var settings: SettingsStore!
    private var pool: EthereumRPCPool!
    private var clock: MutableClock!

    private let alpha = URL(string: "https://alpha.example.com")!
    private let bravo = URL(string: "https://bravo.example.com")!
    private let charlie = URL(string: "https://charlie.example.com")!
    private let delta = URL(string: "https://delta.example.com")!
    private let echo = URL(string: "https://echo.example.com")!

    override func setUp() async throws {
        try await super.setUp()
        let defaults = UserDefaults(suiteName: "AnchorCorroborationTests-\(UUID().uuidString)")!
        settings = SettingsStore(defaults: defaults)
        clock = MutableClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        pool = EthereumRPCPool(settings: settings, clock: { [unowned self] in self.clock.now })
    }

    // MARK: - Helpers

    private func makeCorroboration(
        heads: [URL: UInt64],
        hashes: [URL: [UInt64: String]],
        headCallTracker: ActorCallTracker? = nil
    ) -> AnchorCorroboration {
        let fetchHead: AnchorCorroboration.HeadFetcher = { url, _, _ in
            if let tracker = headCallTracker { await tracker.increment() }
            guard let n = heads[url] else { throw URLError(.badServerResponse) }
            return n
        }
        let fetchHash: AnchorCorroboration.HashFetcher = { url, number, _ in
            guard let byNumber = hashes[url], let h = byNumber[number] else {
                throw URLError(.badServerResponse)
            }
            return h
        }
        return AnchorCorroboration(
            pool: pool,
            settings: settings,
            clock: { [unowned self] in self.clock.now },
            fetchHead: fetchHead,
            fetchHash: fetchHash
        )
    }

    // MARK: - Scenarios

    func testVerifiedFlowReturnsPinnedBlock() async throws {
        settings.ensPublicRpcProviders = [alpha, bravo, charlie].map(\.absoluteString)
        // Heads cluster at 1000; target = 1000 - 8 = 992. All three agree on the hash at 992.
        let anchor = makeCorroboration(
            heads: [alpha: 1000, bravo: 1001, charlie: 999],
            hashes: [
                alpha: [992: "0xaaaa"],
                bravo: [992: "0xaaaa"],
                charlie: [992: "0xaaaa"],
            ]
        )
        let block = try await anchor.getPinnedBlock()
        XCTAssertNotNil(block)
        XCTAssertEqual(block?.number, 992)
        XCTAssertEqual(block?.hash, "0xaaaa")
    }

    func testMedianToleratesSingleOutlierHead() async throws {
        settings.ensPublicRpcProviders = [alpha, bravo, charlie, delta, echo].map(\.absoluteString)
        // Four honest providers cluster near 1000; one liar claims 9_999_999.
        // Sorted [999, 1000, 1001, 1002, 9999999]; median = 1001; target = 993.
        let anchor = makeCorroboration(
            heads: [alpha: 1000, bravo: 1001, charlie: 999, delta: 1002, echo: 9_999_999],
            hashes: [
                alpha: [993: "0xgood"],
                bravo: [993: "0xgood"],
                charlie: [993: "0xgood"],
                delta: [993: "0xgood"],
                echo: [993: "0xattacker"],  // Liar tries to redirect
            ]
        )
        let block = try await anchor.getPinnedBlock()
        XCTAssertEqual(block?.number, 993)
        XCTAssertEqual(block?.hash, "0xgood")
    }

    func testTwoProvidersReturnsNil() async throws {
        // K<3 — single liar could bias anchor within drift, so we degrade
        // rather than claim verified with undefendable metadata.
        settings.ensPublicRpcProviders = [alpha, bravo].map(\.absoluteString)
        let anchor = makeCorroboration(
            heads: [alpha: 1000, bravo: 1001],
            hashes: [:]
        )
        let block = try await anchor.getPinnedBlock()
        XCTAssertNil(block)
    }

    func testAllHeadsFailReturnsNil() async throws {
        settings.ensPublicRpcProviders = [alpha, bravo, charlie].map(\.absoluteString)
        // Empty heads dict → every fetch throws.
        let anchor = makeCorroboration(heads: [:], hashes: [:])
        let block = try await anchor.getPinnedBlock()
        XCTAssertNil(block)
    }

    func testHashDisagreementThrows() async throws {
        settings.ensPublicRpcProviders = [alpha, bravo, charlie].map(\.absoluteString)
        // All agree on head 1000 → target 992. Each returns a different hash.
        // Plurality 1; majority threshold 2. No winner → security signal.
        let anchor = makeCorroboration(
            heads: [alpha: 1000, bravo: 1000, charlie: 1000],
            hashes: [
                alpha: [992: "0xaaaa"],
                bravo: [992: "0xbbbb"],
                charlie: [992: "0xcccc"],
            ]
        )
        do {
            _ = try await anchor.getPinnedBlock()
            XCTFail("expected hashDisagreement")
        } catch AnchorCorroboration.AnchorError.hashDisagreement(_, _, let threshold) {
            XCTAssertEqual(threshold, 2)
        }
    }

    func testPluralityBelowMajorityThrowsEvenAtUserM() async throws {
        // The attacker-resistance case the desktop algorithm was specifically
        // built for: user-M=2 looks like "2 agreeing wins", but if two
        // colluders are inserted into the pool early they could satisfy M=2
        // against a larger honest bucket that just disagreed with each other.
        // Here: 5 heads, all same. At target, 2 return A, 1 each B, C, D.
        // Plurality = A (2). Majority = floor(5/2)+1 = 3. 2 < 3 → throws.
        settings.ensPublicRpcProviders = [alpha, bravo, charlie, delta, echo].map(\.absoluteString)
        settings.ensQuorumM = 2
        let anchor = makeCorroboration(
            heads: [alpha: 1000, bravo: 1000, charlie: 1000, delta: 1000, echo: 1000],
            hashes: [
                alpha: [992: "0xattackerA"],
                bravo: [992: "0xattackerA"],
                charlie: [992: "0xhonestB"],
                delta: [992: "0xhonestC"],
                echo: [992: "0xhonestD"],
            ]
        )
        do {
            _ = try await anchor.getPinnedBlock()
            XCTFail("expected hashDisagreement despite M=2 satisfied")
        } catch AnchorCorroboration.AnchorError.hashDisagreement(let bucket, let total, let threshold) {
            XCTAssertEqual(bucket, 2)
            XCTAssertEqual(total, 5)
            XCTAssertEqual(threshold, 3)
        }
    }

    func testCacheHitDoesNotCallFetchers() async throws {
        settings.ensPublicRpcProviders = [alpha, bravo, charlie].map(\.absoluteString)
        let tracker = ActorCallTracker()
        let anchor = makeCorroboration(
            heads: [alpha: 1000, bravo: 1000, charlie: 1000],
            hashes: [
                alpha: [992: "0xaaaa"],
                bravo: [992: "0xaaaa"],
                charlie: [992: "0xaaaa"],
            ],
            headCallTracker: tracker
        )

        _ = try await anchor.getPinnedBlock()
        let first = await tracker.value
        XCTAssertEqual(first, 3, "first call should probe all 3 providers")

        _ = try await anchor.getPinnedBlock()
        let second = await tracker.value
        XCTAssertEqual(second, 3, "second call within TTL should reuse cache")
    }

    func testCacheExpiresAfterTTL() async throws {
        settings.ensPublicRpcProviders = [alpha, bravo, charlie].map(\.absoluteString)
        settings.ensBlockAnchorTtlMs = 1_000
        let tracker = ActorCallTracker()
        let anchor = makeCorroboration(
            heads: [alpha: 1000, bravo: 1000, charlie: 1000],
            hashes: [
                alpha: [992: "0xaaaa"],
                bravo: [992: "0xaaaa"],
                charlie: [992: "0xaaaa"],
            ],
            headCallTracker: tracker
        )

        _ = try await anchor.getPinnedBlock()
        let afterFirst = await tracker.value
        clock.advance(by: 1.1)
        _ = try await anchor.getPinnedBlock()
        let afterSecond = await tracker.value
        XCTAssertGreaterThan(afterSecond, afterFirst, "expired cache should re-probe")
    }

    func testInvalidateForcesRefetch() async throws {
        settings.ensPublicRpcProviders = [alpha, bravo, charlie].map(\.absoluteString)
        let tracker = ActorCallTracker()
        let anchor = makeCorroboration(
            heads: [alpha: 1000, bravo: 1000, charlie: 1000],
            hashes: [
                alpha: [992: "0xaaaa"],
                bravo: [992: "0xaaaa"],
                charlie: [992: "0xaaaa"],
            ],
            headCallTracker: tracker
        )

        _ = try await anchor.getPinnedBlock()
        let afterFirst = await tracker.value
        anchor.invalidate()
        _ = try await anchor.getPinnedBlock()
        let afterSecond = await tracker.value
        XCTAssertGreaterThan(afterSecond, afterFirst)
    }

    func testAnchorChangeBypassesCache() async throws {
        settings.ensPublicRpcProviders = [alpha, bravo, charlie].map(\.absoluteString)
        let tracker = ActorCallTracker()
        let anchor = makeCorroboration(
            heads: [alpha: 1000, bravo: 1000, charlie: 1000],
            hashes: [
                alpha: [992: "0xaaaa", 968: "0xaaaa"],
                bravo: [992: "0xaaaa", 968: "0xaaaa"],
                charlie: [992: "0xaaaa", 968: "0xaaaa"],
            ],
            headCallTracker: tracker
        )

        settings.ensBlockAnchor = .latest
        _ = try await anchor.getPinnedBlock()
        let afterLatest = await tracker.value

        settings.ensBlockAnchor = .latestMinus32
        _ = try await anchor.getPinnedBlock()
        let afterSwap = await tracker.value
        XCTAssertGreaterThan(afterSwap, afterLatest, "cached entry is anchor-specific")
    }

    func testPartialHashFailureStillReachesMajority() async throws {
        // Three of five providers respond with matching hashes; two fail.
        // 3 of 3 survivors agree → plurality (3) clears majority threshold
        // (3/2 + 1 = 2) and user-M=2. Should succeed.
        settings.ensPublicRpcProviders = [alpha, bravo, charlie, delta, echo].map(\.absoluteString)
        let fetchHead: AnchorCorroboration.HeadFetcher = { _, _, _ in 1000 }
        let fetchHash: AnchorCorroboration.HashFetcher = { url, _, _ in
            switch url {
            case self.alpha, self.bravo, self.charlie: return "0xgood"
            default: throw URLError(.timedOut)
            }
        }
        let corroboration = AnchorCorroboration(
            pool: pool, settings: settings,
            clock: { [unowned self] in self.clock.now },
            fetchHead: fetchHead, fetchHash: fetchHash
        )
        let block = try await corroboration.getPinnedBlock()
        XCTAssertEqual(block?.hash, "0xgood")
    }
}

