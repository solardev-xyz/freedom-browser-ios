import XCTest
@testable import Freedom

/// `ChainlistService` is plain-class + Sendable (not @MainActor), so
/// these tests can run sync. Each test gets a fresh tmp cache file via
/// setUp/tearDown so state doesn't leak across cases.
final class ChainlistServiceTests: XCTestCase {
    private var cacheDir: URL!
    private var cacheURL: URL!

    override func setUp() async throws {
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chainlist-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        cacheURL = cacheDir.appendingPathComponent("rpcs.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: cacheDir)
    }

    private func makeService(
        fetcher: @escaping ChainlistService.Fetcher = { _ in throw URLError(.notConnectedToInternet) },
        now: Date = Date()
    ) -> ChainlistService {
        ChainlistService(cacheURL: cacheURL, fetcher: fetcher, clock: { now })
    }

    // MARK: - Parsing

    func testParsesMinimalEntry() async throws {
        let json = Data("""
        [{
          "name": "Polygon Mainnet",
          "chainId": 137,
          "nativeCurrency": {"name": "Polygon", "symbol": "POL", "decimals": 18},
          "rpc": [{"url": "https://polygon-rpc.com", "tracking": "none"}],
          "explorers": [{"url": "https://polygonscan.com"}]
        }]
        """.utf8)
        let service = makeService(fetcher: { _ in json })
        let chains = try await service.chains()
        XCTAssertEqual(chains, [
            ChainlistService.ImportableChain(
                chainID: 137,
                displayName: "Polygon Mainnet",
                nativeName: "Polygon",
                nativeSymbol: "POL",
                nativeDecimals: 18,
                explorerBase: "https://polygonscan.com",
                rpcURLs: ["https://polygon-rpc.com"]
            ),
        ])
    }

    func testParsesBothStringAndObjectRPCEntries() async throws {
        let json = Data("""
        [{
          "name": "X", "chainId": 1,
          "nativeCurrency": {"name": "ETH", "symbol": "ETH", "decimals": 18},
          "rpc": ["https://a.example.com", {"url": "https://b.example.com"}]
        }]
        """.utf8)
        let service = makeService(fetcher: { _ in json })
        let chains = try await service.chains()
        XCTAssertEqual(chains.first?.rpcURLs, ["https://a.example.com", "https://b.example.com"])
    }

    // MARK: - Filtering

    func testDropsAPIKeyTemplatedURLs() async throws {
        let json = Data("""
        [{
          "name": "X", "chainId": 1,
          "nativeCurrency": {"name": "ETH", "symbol": "ETH", "decimals": 18},
          "rpc": [
            {"url": "https://eth.infura.io/v3/${INFURA_API_KEY}"},
            {"url": "https://eth.alchemy.com/${ALCHEMY_KEY}/whatever"},
            {"url": "https://eth.example.com"}
          ]
        }]
        """.utf8)
        let service = makeService(fetcher: { _ in json })
        let chains = try await service.chains()
        XCTAssertEqual(chains.first?.rpcURLs, ["https://eth.example.com"])
    }

    func testDropsTrackingMarkedURLsKeepsNoneOrMissing() async throws {
        let json = Data("""
        [{
          "name": "X", "chainId": 1,
          "nativeCurrency": {"name": "ETH", "symbol": "ETH", "decimals": 18},
          "rpc": [
            {"url": "https://yes.example.com", "tracking": "yes"},
            {"url": "https://limited.example.com", "tracking": "limited"},
            {"url": "https://none.example.com", "tracking": "none"},
            {"url": "https://noflag.example.com"}
          ]
        }]
        """.utf8)
        let service = makeService(fetcher: { _ in json })
        let chains = try await service.chains()
        XCTAssertEqual(
            chains.first?.rpcURLs,
            ["https://none.example.com", "https://noflag.example.com"]
        )
    }

    func testDropsMalformedRPCURLs() async throws {
        let json = Data("""
        [{
          "name": "X", "chainId": 1,
          "nativeCurrency": {"name": "ETH", "symbol": "ETH", "decimals": 18},
          "rpc": [
            "ws://stream.example.com",
            "not-a-url",
            "https://ok.example.com"
          ]
        }]
        """.utf8)
        let service = makeService(fetcher: { _ in json })
        let chains = try await service.chains()
        XCTAssertEqual(chains.first?.rpcURLs, ["https://ok.example.com"])
    }

    func testDropsChainWithNoAcceptedRPCs() async throws {
        let json = Data("""
        [{
          "name": "X", "chainId": 1,
          "nativeCurrency": {"name": "ETH", "symbol": "ETH", "decimals": 18},
          "rpc": [{"url": "https://x.example.com/v3/${KEY}"}, {"url": "https://y.example.com", "tracking": "yes"}]
        }]
        """.utf8)
        let service = makeService(fetcher: { _ in json })
        let chains = try await service.chains()
        XCTAssertTrue(chains.isEmpty)
    }

    func testDropsChainWithoutNativeCurrency() async throws {
        let json = Data("""
        [{
          "name": "X", "chainId": 1,
          "rpc": [{"url": "https://x.example.com"}]
        }]
        """.utf8)
        let service = makeService(fetcher: { _ in json })
        let chains = try await service.chains()
        XCTAssertTrue(chains.isEmpty)
    }

    func testDropsChainWithEmptyDisplayStrings() async throws {
        // A drifted entry with blank name/symbol would render as an empty
        // row in the search UI — skip it at parse time.
        let json = Data("""
        [
          {
            "name": "",
            "chainId": 1,
            "nativeCurrency": {"name": "ETH", "symbol": "ETH", "decimals": 18},
            "rpc": [{"url": "https://x.example.com"}]
          },
          {
            "name": "X", "chainId": 2,
            "nativeCurrency": {"name": "", "symbol": "ETH", "decimals": 18},
            "rpc": [{"url": "https://x.example.com"}]
          },
          {
            "name": "X", "chainId": 3,
            "nativeCurrency": {"name": "ETH", "symbol": "", "decimals": 18},
            "rpc": [{"url": "https://x.example.com"}]
          }
        ]
        """.utf8)
        let service = makeService(fetcher: { _ in json })
        let chains = try await service.chains()
        XCTAssertTrue(chains.isEmpty)
    }

    func testDropsChainWithUnreasonableDecimals() async throws {
        let json = Data("""
        [{
          "name": "X", "chainId": 1,
          "nativeCurrency": {"name": "ETH", "symbol": "ETH", "decimals": 1800},
          "rpc": [{"url": "https://x.example.com"}]
        }]
        """.utf8)
        let service = makeService(fetcher: { _ in json })
        let chains = try await service.chains()
        XCTAssertTrue(chains.isEmpty)
    }

    func testToleratesMalformedChainAmongValidOnes() async throws {
        let json = Data("""
        [
          {"chainId": "should-be-int"},
          {
            "name": "Good", "chainId": 1,
            "nativeCurrency": {"name": "ETH", "symbol": "ETH", "decimals": 18},
            "rpc": [{"url": "https://eth.example.com"}]
          }
        ]
        """.utf8)
        let service = makeService(fetcher: { _ in json })
        let chains = try await service.chains()
        XCTAssertEqual(chains.count, 1)
        XCTAssertEqual(chains.first?.chainID, 1)
    }

    // MARK: - Cache

    func testCacheHitWithinTTLSkipsFetcher() async throws {
        let json = Data("""
        [{
          "name": "X", "chainId": 1,
          "nativeCurrency": {"name": "ETH", "symbol": "ETH", "decimals": 18},
          "rpc": [{"url": "https://x.example.com"}]
        }]
        """.utf8)
        try json.write(to: cacheURL)
        let counter = FetchCounter()
        // Clock is 1 hour after the cache write — well within TTL.
        let service = makeService(
            fetcher: { _ in
                await counter.bump()
                throw URLError(.cancelled)
            },
            now: Date().addingTimeInterval(3600)
        )
        _ = try await service.chains()
        let count = await counter.count
        XCTAssertEqual(count, 0)
    }

    func testCacheMissTriggersFetchAndWritesCache() async throws {
        let json = Data("""
        [{
          "name": "X", "chainId": 1,
          "nativeCurrency": {"name": "ETH", "symbol": "ETH", "decimals": 18},
          "rpc": [{"url": "https://x.example.com"}]
        }]
        """.utf8)
        let service = makeService(fetcher: { _ in json })
        _ = try await service.chains()
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testStaleCacheUsedAsFallbackWhenFetcherFails() async throws {
        let json = Data("""
        [{
          "name": "X", "chainId": 1,
          "nativeCurrency": {"name": "ETH", "symbol": "ETH", "decimals": 18},
          "rpc": [{"url": "https://x.example.com"}]
        }]
        """.utf8)
        try json.write(to: cacheURL)
        // Backdate the cache by 48h so the freshness check fails.
        let oldDate = Date().addingTimeInterval(-48 * 3600)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: cacheURL.path)

        let service = makeService(fetcher: { _ in throw URLError(.notConnectedToInternet) })
        let chains = try await service.chains()
        XCTAssertEqual(chains.first?.chainID, 1)
    }

    func testFetchFailureWithoutCacheThrows() async throws {
        let service = makeService(fetcher: { _ in throw URLError(.notConnectedToInternet) })
        do {
            _ = try await service.chains()
            XCTFail("expected throw")
        } catch is URLError {
            // expected
        } catch {
            XCTFail("expected URLError, got \(error)")
        }
    }

    func testMalformedFetchedDataFallsBackToStaleCacheIfPresent() async throws {
        let cachedJSON = Data("""
        [{
          "name": "X", "chainId": 1,
          "nativeCurrency": {"name": "ETH", "symbol": "ETH", "decimals": 18},
          "rpc": [{"url": "https://x.example.com"}]
        }]
        """.utf8)
        try cachedJSON.write(to: cacheURL)
        let oldDate = Date().addingTimeInterval(-48 * 3600)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: cacheURL.path)

        let service = makeService(fetcher: { _ in Data("<html>upstream error</html>".utf8) })
        let chains = try await service.chains()
        XCTAssertEqual(chains.first?.chainID, 1, "stale cache should rescue a malformed fetch")
    }
}

private actor FetchCounter {
    var count = 0
    func bump() { count += 1 }
}
