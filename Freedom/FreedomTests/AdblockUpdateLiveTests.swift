import WebKit
import XCTest
@testable import Freedom

/// Full-stack e2e against the LIVE Swarm mainnet feed, read through a local
/// Ant/bee node on `127.0.0.1:1699` (the publisher-side dev node; the
/// simulator shares the host's loopback). Skips when no node is listening.
///
/// Exercises the entire production pipeline with zero stubs except the node
/// port: real feed read by (owner, topic) → real EIP-191 verification of the
/// live manifest → download every iOS shard from Swarm → sha256 verify →
/// REAL `WKContentRuleListStore` compiles → promote + activate.
@MainActor
final class AdblockUpdateLiveTests: XCTestCase {
    private static let nodeURL = URL(string: "http://127.0.0.1:1699")!
    /// The production feed (see AdblockUpdateFeed) — the e2e exercises the
    /// exact feed shipped clients will read.
    private static let feedOwner = "0xb818FF019BC15BC3DfbdaD4CE0ab66A6f74e8f1E"

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("adblock-live-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removeObject(forKey: "adblock.update.lastCheck")
    }

    private func skipUnlessNodeIsUp() async throws {
        var request = URLRequest(url: Self.nodeURL.appendingPathComponent("health"))
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw XCTSkip("node on :1699 not healthy")
            }
        } catch is XCTSkip {
            throw XCTSkip("node on :1699 not healthy")
        } catch {
            throw XCTSkip("no local node on :1699 — start the publisher dev node to run this e2e")
        }
    }

    private func liveIO(compiled: NSMutableArray, activated: NSMutableArray) -> AdblockUpdateService.IO {
        AdblockUpdateService.IO(
            readFeed: {
                let owner = Self.feedOwner.lowercased().replacingOccurrences(of: "0x", with: "")
                let topic = AdblockUpdateFeed.feedTopicHex
                let url = Self.nodeURL.appendingPathComponent("feeds/\(owner)/\(topic)")
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw BeeAPIClient.Error.notFound
                }
                return data
            },
            downloadBlob: { ref in
                // Swarm retrievals of ~2MB blobs occasionally stall mid-body
                // while the node is still discovering chunks; production
                // shrugs (next 6h tick retries), the e2e retries in-place.
                var lastError: Error = BeeAPIClient.Error.notFound
                for attempt in 1...3 {
                    do {
                        let url = Self.nodeURL.appendingPathComponent("bytes/\(ref)")
                        var request = URLRequest(url: url)
                        request.timeoutInterval = 120
                        let (data, response) = try await URLSession.shared.data(for: request)
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                            throw BeeAPIClient.Error.notFound
                        }
                        return data
                    } catch {
                        lastError = error
                        if attempt < 3 { try await Task.sleep(for: .seconds(2)) }
                    }
                }
                throw lastError
            },
            rootDir: root,
            sigAddress: Self.feedOwner,
            trustConfigured: true,
            precompile: { manifest, dir, feedVersion in
                // REAL WebKit compiles of every Swarm-delivered shard.
                let store = try XCTUnwrap(WKContentRuleListStore.default())
                for entry in manifest.categories {
                    for shard in entry.shards {
                        let identifier = "freedom-adblock-e2e.v\(feedVersion).\(shard.filenameStem)"
                        let json = try String(
                            contentsOf: dir.appendingPathComponent(shard.filename), encoding: .utf8
                        )
                        let list: WKContentRuleList? = try await withCheckedThrowingContinuation { cont in
                            store.compileContentRuleList(
                                forIdentifier: identifier, encodedContentRuleList: json
                            ) { list, error in
                                if let error { cont.resume(throwing: error) } else { cont.resume(returning: list) }
                            }
                        }
                        XCTAssertNotNil(list, "compiled \(identifier)")
                        compiled.add(identifier)
                    }
                }
            },
            activate: { feedVersion, _ in
                activated.add(feedVersion)
            }
        )
    }

    func testLiveFeedUpdateAppliesEndToEnd() async throws {
        try await skipUnlessNodeIsUp()

        let compiled = NSMutableArray()
        let activated = NSMutableArray()
        let service = AdblockUpdateService(
            settings: SettingsStore(), io: liveIO(compiled: compiled, activated: activated)
        )

        let outcome = await service.runOnce()

        guard case .applied(let version) = outcome else {
            return XCTFail("expected .applied, got \(outcome)")
        }
        XCTAssertGreaterThanOrEqual(version, 1, "production feed starts at v1")
        XCTAssertEqual(activated.count, 1)
        XCTAssertGreaterThanOrEqual(compiled.count, 10, "all live iOS shards compiled (15 at v4)")

        // The applied state + files landed, and a re-run is a no-op.
        XCTAssertEqual(AdblockUpdateService.appliedState(rootDir: root)?.feedVersion, version)
        let second = await service.runOnce()
        XCTAssertEqual(second, .notNewer(version: version))

        // Downgrade protection against the live feed, from a future version.
        let updatedDir = root.appendingPathComponent("updated")
        let state = try JSONSerialization.data(withJSONObject: ["feed_version": version + 100])
        try state.write(to: updatedDir.appendingPathComponent("state.json"))
        let third = await service.runOnce()
        XCTAssertEqual(third, .notNewer(version: version))

        // Cleanup WebKit's compiled-list cache (best effort).
        if let store = WKContentRuleListStore.default() {
            for case let identifier as String in compiled {
                store.removeContentRuleList(forIdentifier: identifier) { _ in }
            }
        }
    }
}
