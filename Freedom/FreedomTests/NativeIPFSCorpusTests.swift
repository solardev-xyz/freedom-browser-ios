import IPFSKit
import WebKit
import XCTest
@testable import Freedom

/// Browser smoke harness — drives the production `IpfsSchemeHandler`
/// through a corpus of ipfs:// URLs, captures per-load metrics, and
/// writes a JSON report. Disabled by default; opt in via
/// `FREEDOM_CORPUS=1`. Network-dependent (real ENS + IPFS retrieval).
///
/// Run native:
///
///   FREEDOM_CORPUS=1 xcodebuild test \
///     -project Freedom/Freedom.xcodeproj \
///     -scheme Freedom \
///     -destination 'id=<sim-udid>' \
///     -only-testing FreedomTests/NativeIPFSCorpusTests/testNativeCorpus
///
/// Output: /tmp/freedom-corpus-results-native.json (or -loopback.json).
@MainActor
final class NativeIPFSCorpusTests: XCTestCase {

    private static let corpus: [String] = [
        "ipfs://vitalik.eth/",
        "ipfs://ens.eth/",
        "ipfs://daicowtf.eth/",
        "ipfs://jthor.eth/",
        "ipfs://cowswap.eth/",
        "ipfs://ipfs.tech/",
    ]

    private static let nodeStartTimeoutSeconds: TimeInterval = 30
    private static let perLoadTimeoutSeconds: TimeInterval = 60
    private static let postLoadSettleSeconds: TimeInterval = 1.5

    override func setUp() async throws {
        try await super.setUp()
        if ProcessInfo.processInfo.environment["FREEDOM_CORPUS"] != "1" {
            throw XCTSkip("Set FREEDOM_CORPUS=1 to run the IPFS corpus harness")
        }
    }

    func testNativeCorpus() async throws {
        try await runCorpus(
            transport: .nativeFFI,
            outputPath: "/tmp/freedom-corpus-results-native.json"
        )
    }

    func testLoopbackCorpus() async throws {
        try await runCorpus(
            transport: .loopbackHTTP,
            outputPath: "/tmp/freedom-corpus-results-loopback.json"
        )
    }

    // MARK: - Harness

    private func runCorpus(transport: IPFSGatewayTransport, outputPath: String) async throws {
        var results: [RunResult] = []
        for url in Self.corpus {
            let result = await loadOnce(urlString: url, transport: transport)
            results.append(result)
        }
        try writeResults(results, transport: transport, outputPath: outputPath)
    }

    /// Fresh `IPFSNode` per URL — cold-cache scenario.
    private func loadOnce(urlString: String, transport: IPFSGatewayTransport) async -> RunResult {
        let dataDir = makeTemporaryDataDir()
        let settings = SettingsStore(defaults: makeEphemeralDefaults())
        settings.ipfsGatewayTransport = transport

        let node = IPFSNode()
        node.start(settings.ipfsConfig(dataDir: dataDir))
        guard await waitForNodeRunning(node) else {
            return RunResult.failure(url: urlString, transport: transport, message: "node failed to start within \(Self.nodeStartTimeoutSeconds)s")
        }

        let pool = EthereumRPCPool(settings: settings)
        let resolver = ENSResolver(pool: pool, settings: settings)
        let navContext = IpfsNavContext()

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(
            IpfsSchemeHandler(node: node, ensResolver: resolver, navContext: navContext, settings: settings),
            forURLScheme: "ipfs"
        )
        config.setURLSchemeHandler(
            IpfsSchemeHandler(node: node, ensResolver: resolver, navContext: navContext, settings: settings),
            forURLScheme: "ipns"
        )

        let webView = WKWebView(frame: .zero, configuration: config)
        let delegate = NavCapture()
        webView.navigationDelegate = delegate

        guard let url = URL(string: urlString) else {
            await teardown(node)
            return RunResult.failure(url: urlString, transport: transport, message: "invalid URL")
        }
        if let path = IpfsSchemeHandler.gatewayStylePath(for: url) {
            navContext.begin(topLevelPath: path)
        }

        let baselineDiagnostics = node.diagnostics
        let started = Date()
        webView.load(URLRequest(url: url))
        let outcome = await delegate.waitForOutcome(timeout: Self.perLoadTimeoutSeconds)
        let finished = Date()

        try? await Task.sleep(nanoseconds: UInt64(Self.postLoadSettleSeconds * 1_000_000_000))

        let title = (try? await webView.evaluateJavaScript("document.title")) as? String ?? ""
        let bodyLength = (try? await webView.evaluateJavaScript(
            "document.body ? document.body.innerText.length : 0"
        )) as? Int ?? 0

        let finalDiagnostics = node.diagnostics
        let progressJSON = node.progressSnapshotJSON ?? "{}"

        navContext.end()
        await teardown(node)

        return RunResult(
            url: urlString,
            transport: String(describing: transport),
            success: outcome == .didFinish,
            errorMessage: outcome.errorMessage,
            durationMs: Int(finished.timeIntervalSince(started) * 1000),
            title: title,
            bodyTextLength: bodyLength,
            diagnostics: DiagnosticsSnapshot(before: baselineDiagnostics, after: finalDiagnostics),
            progressSnapshotJSON: progressJSON
        )
    }

    private func waitForNodeRunning(_ node: IPFSNode) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: Self.nodeStartTimeoutSeconds)
        while Date() < deadline {
            if node.status == .running { return true }
            if node.status == .failed { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return node.status == .running
    }

    private func teardown(_ node: IPFSNode) async {
        node.stop()
        let deadline = Date(timeIntervalSinceNow: 10)
        while Date() < deadline, node.status != .stopped {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func makeTemporaryDataDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("freedom-corpus-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeEphemeralDefaults() -> UserDefaults {
        let suite = "freedom.corpus.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? .standard
    }

    private func writeResults(
        _ results: [RunResult],
        transport: IPFSGatewayTransport,
        outputPath: String
    ) throws {
        let report = CorpusReport(
            transport: String(describing: transport),
            timestamp: ISO8601DateFormatter().string(from: Date()),
            runs: results
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: URL(fileURLWithPath: outputPath))
        print("freedom-corpus: wrote \(results.count) runs to \(outputPath)")
    }
}

// MARK: - Models

private struct CorpusReport: Encodable {
    let transport: String
    let timestamp: String
    let runs: [RunResult]
}

private struct RunResult: Encodable {
    let url: String
    let transport: String
    let success: Bool
    let errorMessage: String?
    let durationMs: Int
    let title: String
    let bodyTextLength: Int
    let diagnostics: DiagnosticsSnapshot
    let progressSnapshotJSON: String

    static func failure(url: String, transport: IPFSGatewayTransport, message: String) -> RunResult {
        RunResult(
            url: url,
            transport: String(describing: transport),
            success: false,
            errorMessage: message,
            durationMs: 0,
            title: "",
            bodyTextLength: 0,
            diagnostics: DiagnosticsSnapshot.empty,
            progressSnapshotJSON: "{}"
        )
    }
}

private struct DiagnosticsSnapshot: Encodable {
    let blockCountBefore: UInt64
    let blockCountAfter: UInt64
    let totalBytesBefore: UInt64
    let totalBytesAfter: UInt64
    let cacheHitsBefore: UInt64
    let cacheHitsAfter: UInt64
    let httpProviderBlocksBefore: UInt64
    let httpProviderBlocksAfter: UInt64
    let bitswapBlocksBefore: UInt64
    let bitswapBlocksAfter: UInt64
    let activePreloadCountAfter: UInt64

    init(before: FreedomIpfsDiagnostics?, after: FreedomIpfsDiagnostics?) {
        self.blockCountBefore = before?.stats.blockCount ?? 0
        self.blockCountAfter = after?.stats.blockCount ?? 0
        self.totalBytesBefore = before?.stats.totalBytes ?? 0
        self.totalBytesAfter = after?.stats.totalBytes ?? 0
        self.cacheHitsBefore = before?.retrievalStats.cacheHits ?? 0
        self.cacheHitsAfter = after?.retrievalStats.cacheHits ?? 0
        self.httpProviderBlocksBefore = before?.retrievalStats.httpProviderBlocks ?? 0
        self.httpProviderBlocksAfter = after?.retrievalStats.httpProviderBlocks ?? 0
        self.bitswapBlocksBefore = before?.retrievalStats.bitswapBlocks ?? 0
        self.bitswapBlocksAfter = after?.retrievalStats.bitswapBlocks ?? 0
        self.activePreloadCountAfter = after?.activePreloadCount ?? 0
    }

    private init() {
        self.blockCountBefore = 0
        self.blockCountAfter = 0
        self.totalBytesBefore = 0
        self.totalBytesAfter = 0
        self.cacheHitsBefore = 0
        self.cacheHitsAfter = 0
        self.httpProviderBlocksBefore = 0
        self.httpProviderBlocksAfter = 0
        self.bitswapBlocksBefore = 0
        self.bitswapBlocksAfter = 0
        self.activePreloadCountAfter = 0
    }

    static let empty = DiagnosticsSnapshot()
}

// MARK: - WKNavigationDelegate capture

@MainActor
private final class NavCapture: NSObject, WKNavigationDelegate {
    enum Outcome: Equatable {
        case didFinish
        case didFail(message: String)
        case timeout

        var errorMessage: String? {
            switch self {
            case .didFinish: return nil
            case .didFail(let m): return m
            case .timeout: return "timeout"
            }
        }
    }

    private var continuation: CheckedContinuation<Outcome, Never>?
    private var fired = false

    func waitForOutcome(timeout: TimeInterval) async -> Outcome {
        let outcome = await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
            self.continuation = cont
            // Timeout fallback.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await MainActor.run {
                    self?.fire(.timeout)
                }
            }
        }
        return outcome
    }

    private func fire(_ outcome: Outcome) {
        guard !fired else { return }
        fired = true
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.fire(.didFinish) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        Task { @MainActor in self.fire(.didFail(message: error.localizedDescription)) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        Task { @MainActor in self.fire(.didFail(message: error.localizedDescription)) }
    }
}
