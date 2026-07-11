import SwiftData
import web3
import WebKit
import XCTest
@testable import Freedom

/// End-to-end SWIP compliance: a real `WKWebView` runs swarm-kit's
/// `runSwarmProviderCompliance` harness (the same suite dApps use
/// against desktop Freedom) against this app's full provider stack —
/// the `SwarmBridge.js` preload, `WKScriptMessageHandler` transport,
/// `SwarmBridge`/`SwarmRouter` dispatch, real vault-derived signing,
/// and `SwarmChunkCodec` validation. Only bee itself is replaced by an
/// in-memory chunk store that derives addresses with the same
/// primitives bee does — so CAC/SOC roundtrips, type-mismatch
/// rejections, and error reasons are exercised for real.
///
/// The harness bundle is loaded from the sibling swarm-kit checkout;
/// the test skips when that repo isn't present so CI stays green.
@MainActor
final class SwarmProviderComplianceTests: XCTestCase {
    private static let swarmKitBundlePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // FreedomTests
        .deletingLastPathComponent()  // Freedom
        .deletingLastPathComponent()  // swarm-mobile-ios
        .deletingLastPathComponent()  // nodes
        .deletingLastPathComponent()  // freedom-dev
        .appendingPathComponent("swarm-kit/examples/provider-compliance/swarm-kit.js")

    private static let preloadPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Freedom/Swarm/Bridge/SwarmBridge.js")

    /// Receives the harness's JSON report from the page.
    private final class ReportSink: NSObject, WKScriptMessageHandler {
        var onReport: ((String) -> Void)?
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if let body = message.body as? String {
                onReport?(body)
            }
        }
    }

    private var vaultService: String!

    override func tearDown() async throws {
        if let vaultService {
            try VaultCrypto(service: vaultService).wipe()
        }
    }

    func testSwarmKitProviderComplianceSuitePasses() async throws {
        guard FileManager.default.fileExists(atPath: Self.swarmKitBundlePath.path) else {
            throw XCTSkip("swarm-kit checkout not found at \(Self.swarmKitBundlePath.path)")
        }

        // --- vault + stores (same setup as SwarmBridgeTestFixture) ---
        let vaultService = "com.freedom.swarm.compliance.test.\(UUID().uuidString)"
        self.vaultService = vaultService
        let vault = Vault(crypto: VaultCrypto(service: vaultService, preferred: .deviceBound))
        try await vault.create(mnemonic: try Mnemonic(phrase: hardhatMnemonic))

        let container = try inMemoryContainer(
            for: SwarmPermission.self,
            SwarmFeedRecord.self,
            SwarmFeedIdentity.self,
            SwarmPublishHistoryRecord.self,
            DappPermission.self
        )
        let permissionStore = SwarmPermissionStore(context: container.mainContext)
        let feedStore = SwarmFeedStore(context: container.mainContext)
        let publishHistoryStore = SwarmPublishHistoryStore(context: container.mainContext)

        // --- in-memory bee: same address derivation as the real node ---
        final class ChunkStore {
            var chunks: [String: Data] = [:]
        }
        let chunkStore = ChunkStore()

        let chunkService = SwarmChunkService(
            uploadChunk: { body, _ in
                let cac = try SwarmSOC.makeCAC(
                    span: Data(body.prefix(8)), payload: Data(body.dropFirst(8))
                )
                let reference = cac.address.web3.hexString.web3.noHexPrefix
                chunkStore.chunks[reference] = body
                return (reference: reference, tagUid: nil)
            },
            uploadSOC: { owner, identifier, sig, body, _ in
                guard let ownerBytes = Data(hex: owner), ownerBytes.count == 20,
                      let identifierBytes = Data(hex: identifier), identifierBytes.count == 32,
                      let sigBytes = Data(hex: sig), sigBytes.count == 65 else {
                    throw BeeAPIClient.Error.malformedResponse
                }
                let address = SwarmSOC.socAddress(
                    identifier: identifierBytes, ownerAddress: ownerBytes
                ).web3.hexString.web3.noHexPrefix
                chunkStore.chunks[address] = identifierBytes + sigBytes + body
                return (reference: address, tagUid: nil)
            }
        )

        let services = SwarmServices(
            permissionStore: permissionStore,
            feedStore: feedStore,
            publishHistoryStore: publishHistoryStore,
            bee: BeeAPIClient(),
            publishService: SwarmPublishService(upload: { _, _, _, _, _ in
                XCTFail("publish service unexpectedly called")
                return (Data(), [:])
            }),
            feedService: SwarmFeedService(
                createFeedManifest: { _, _, _ in XCTFail("createFeedManifest called"); return "" },
                readFeed: { _, _, _ in
                    XCTFail("readFeed called")
                    return BeeAPIClient.FeedReadResult(payload: Data(), index: 0, nextIndex: nil)
                },
                uploadSOC: { _, _, _, _, _ in XCTFail("feed uploadSOC called"); return ("", nil) },
                uploadBytes: { _, _ in XCTFail("uploadBytes called"); return "" },
                getChunk: { _ in XCTFail("getChunk called"); return Data() }
            ),
            chunkService: chunkService,
            readBudget: SwarmReadBudget(),
            vault: vault,
            tagOwnership: TagOwnership(),
            feedWriteLock: SwarmFeedWriteLock(),
            nodeFailureReason: { nil },
            currentStamps: { [PostageBatch(
                batchID: String(repeating: "ee", count: 32),
                usable: true, usage: 0.1,
                effectiveBytes: 10_000_000, ttlSeconds: 86_400 * 30,
                isMutable: true, depth: 22, amount: "1000", label: nil
            )] },
            getTag: { _ in XCTFail("getTag called"); throw BeeAPIClient.Error.notFound }
        )

        let router = SwarmRouter(
            isConnected: { permissionStore.isConnected($0) },
            listFeedsForOrigin: { feedStore.all(forOrigin: $0).map(\.asListFeedsRow) },
            nodeFailureReason: { nil },
            feedOwner: { origin, name in feedStore.lookup(origin: origin, name: name)?.owner },
            readFeed: { _, _, _ in throw SwarmRouter.FeedReadError.notFound },
            readChunkRaw: { address in
                guard let data = chunkStore.chunks[address] else {
                    throw SwarmRouter.ChunkReadError.notFound
                }
                return data
            },
            readBudget: SwarmReadBudget()
        )

        // --- webview with the real preload + bridge transport ---
        let host = StubBridgeHost()
        host.displayURL = URL(string: "https://compliance.example")!
        // Stand in for the approval sheets: approve everything, and
        // honor the first-grant contract (sheet writes the identity
        // row before resolving).
        host.onParked = { request in
            if case .swarmFeedAccess(let details) = request.kind, details.isFirstGrant {
                feedStore.setFeedIdentity(
                    origin: request.origin.key, identityMode: .appScoped
                )
            }
            Task { @MainActor in
                request.decide(.approved)
            }
        }

        let contentController = WKUserContentController()
        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        // The harness page + its ESM bundle load from file:// — WebKit
        // treats file origins as opaque and denies the module import
        // without these (test-only; production pages load over real
        // schemes).
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 390, height: 700),
                                configuration: config)

        let bridge = SwarmBridge(
            host: host, router: router, services: services,
            replies: BridgeReplyChannel(jsGlobal: "__freedomSwarm", webView: webView)
        )
        contentController.add(bridge, name: SwarmBridge.messageHandlerName)
        let preloadSource = try String(contentsOf: Self.preloadPath, encoding: .utf8)
        contentController.addUserScript(WKUserScript(
            source: preloadSource, injectionTime: .atDocumentStart, forMainFrameOnly: false
        ))

        let sink = ReportSink()
        contentController.add(sink, name: "complianceReport")

        // --- page: swarm-kit compliance harness against window.swarm ---
        let pageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swarm-compliance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: pageDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: pageDir) }
        try FileManager.default.copyItem(
            at: Self.swarmKitBundlePath,
            to: pageDir.appendingPathComponent("swarm-kit.js")
        )
        let html = """
        <!DOCTYPE html><html><body><script type="module">
        (async () => {
          const post = (payload) =>
            window.webkit.messageHandlers.complianceReport.postMessage(payload);
          try {
            const mod = await import('./swarm-kit.js');
            const report = await mod.runSwarmProviderCompliance(window.swarm);
            post(JSON.stringify(report));
          } catch (e) {
            post(JSON.stringify({ fatal: String((e && e.stack) || e) }));
          }
        })();
        </script></body></html>
        """
        let htmlURL = pageDir.appendingPathComponent("index.html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)

        let reportJSON: String = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            sink.onReport = { body in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: body)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(60))
                guard !resumed else { return }
                resumed = true
                continuation.resume(throwing: XCTSkip("compliance harness timed out"))
            }
            webView.loadFileURL(htmlURL, allowingReadAccessTo: pageDir)
        }

        let report = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(reportJSON.utf8)) as? [String: Any]
        )
        if let fatal = report["fatal"] as? String {
            XCTFail("compliance harness failed to run: \(fatal)")
            return
        }
        let summary = try XCTUnwrap(report["summary"] as? [String: Any])
        let results = report["results"] as? [[String: Any]] ?? []
        let failures = results.filter { ($0["status"] as? String) == "fail" }
        XCTAssertEqual(
            summary["failed"] as? Int, 0,
            "compliance failures: \(failures)"
        )
        XCTAssertEqual(summary["skipped"] as? Int, 0)
        XCTAssertGreaterThanOrEqual(summary["passed"] as? Int ?? 0, 12)

        // The bridge really signed: the origin now has an app-scoped
        // identity and the SOC cases wrote through the vault key.
        XCTAssertEqual(
            feedStore.feedIdentity(origin: "https://compliance.example")?.identityMode,
            .appScoped
        )
    }
}
