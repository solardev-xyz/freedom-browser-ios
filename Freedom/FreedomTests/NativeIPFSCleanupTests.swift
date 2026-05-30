import IPFSKit
import WebKit
import XCTest
@testable import Freedom

/// Opt-in integration harness for native FFI cleanup invariants under
/// lifecycle disturbances: explicit `webView.stopLoading()`, concurrent
/// re-navigation, and `handler.invalidate()` (the path `BrowserTab`
/// uses on tab close). Each test asserts the same invariant that the
/// corpus harness's `nativeGatewayStatsJSONPostDrain` already enforces
/// for happy-path loads — `active_native_handles` returns to 0 — but
/// here under deliberate cancellation rather than completion.
///
/// Disabled by default; opt in via `TEST_RUNNER_FREEDOM_CLEANUP=1`.
/// Network-dependent (real ENS resolution + IPFS retrieval). The
/// `TEST_RUNNER_` prefix is required so xcodebuild forwards the env
/// var into the simulator test runner.
///
///   TEST_RUNNER_FREEDOM_CLEANUP=1 xcodebuild test \
///     -project Freedom/Freedom.xcodeproj \
///     -scheme Freedom \
///     -destination 'id=<sim-udid>' \
///     -only-testing FreedomTests/NativeIPFSCleanupTests
@MainActor
final class NativeIPFSCleanupTests: XCTestCase {

    private static let primaryURL = "ipfs://vitalik.eth/"
    private static let secondaryURL = "ipfs://daicowtf.eth/"

    private static let nodeStartTimeoutSeconds: TimeInterval = 30
    private static let perLoadTimeoutSeconds: TimeInterval = 60
    /// Wait at most this long for the first native request to spin up
    /// (ENS resolution → handleENSResolved → startNativeUpstream).
    /// Real-network ENS RPC can take a couple of seconds cold; an
    /// opt-in harness can afford a generous cap.
    private static let nativeRequestStartTimeoutSeconds: TimeInterval = 15
    /// How long the cleanup pathway has after the disturbance to drain
    /// all in-flight requests back to 0. Real ENS RPC cancellation is
    /// cooperative (the `Task` only observes the flag when it next
    /// awaits), so this needs to outlast the slowest ENS query.
    private static let cleanupSettleCapSeconds: TimeInterval = 30

    /// Same workaround as `NativeIPFSCorpusTests` — Swift's
    /// `swift_task_deinitOnExecutor` machinery still crashes in
    /// `~StopLookupScope` when @MainActor classes from the IPFS stack
    /// release per-iteration on iOS 18. Acceptable for an opt-in
    /// harness; the production app reuses one set of these for the
    /// process lifetime.
    nonisolated(unsafe) private static var leakedDependencies: [AnyObject] = []

    override func setUp() async throws {
        try await super.setUp()
        if ProcessInfo.processInfo.environment["FREEDOM_CLEANUP"] != "1" {
            throw XCTSkip("Set TEST_RUNNER_FREEDOM_CLEANUP=1 to run the IPFS cleanup harness")
        }
    }

    /// Explicit `webView.stopLoading()` mid-flight (e.g. user taps the
    /// stop button). Every in-flight scheme task should reach the sink's
    /// cancel path and free its Rust handle.
    func testStopLoadingMidFlightDrainsNativeHandles() async throws {
        let env = try await makeEnv()
        defer { Self.leak(env) }

        env.webView.load(URLRequest(url: URL(string: Self.primaryURL)!))
        try await waitUntilNativeHandlesActive(env: env)

        env.webView.stopLoading()
        await waitForInFlightQuiesce(env: env)

        XCTAssertEqual(activeNativeHandles(node: env.node), 0,
                       "stopLoading() should drain all native handles")
        XCTAssertEqual(handlerInFlight(env: env), 0,
                       "Scheme handler in-flight tracking should also drain")
    }

    /// Second `webView.load(...)` mid-flight — WK cancels the first
    /// load internally and starts the second. Every cancelled scheme
    /// task should reach the sink's cancel path.
    func testConcurrentNavigationDrainsNativeHandles() async throws {
        let env = try await makeEnv()
        defer { Self.leak(env) }

        env.webView.load(URLRequest(url: URL(string: Self.primaryURL)!))
        try await waitUntilNativeHandlesActive(env: env)

        env.webView.load(URLRequest(url: URL(string: Self.secondaryURL)!))
        // Wait for the second navigation to either finish or fail —
        // by then the first load's cancel path has had time to run.
        _ = await env.delegate.waitForOutcome(timeout: Self.perLoadTimeoutSeconds)
        await waitForInFlightQuiesce(env: env)

        XCTAssertEqual(activeNativeHandles(node: env.node), 0,
                       "Concurrent re-navigation should leave no leaked native handles")
        XCTAssertEqual(handlerInFlight(env: env), 0,
                       "Scheme handler in-flight tracking should also drain")
    }

    /// `handler.invalidate()` mid-flight — the cleanup path
    /// `BrowserTab` runs when a tab is closed. Should cancel + free
    /// every active native handle synchronously.
    func testInvalidateMidFlightDrainsNativeHandles() async throws {
        let env = try await makeEnv()
        defer { Self.leak(env) }

        env.webView.load(URLRequest(url: URL(string: Self.primaryURL)!))
        try await waitUntilNativeHandlesActive(env: env)

        env.handlerIpfs.invalidate()
        env.handlerIpns.invalidate()
        await waitForInFlightQuiesce(env: env)

        XCTAssertEqual(activeNativeHandles(node: env.node), 0,
                       "handler.invalidate() should drain all native handles")
        XCTAssertEqual(handlerInFlight(env: env), 0,
                       "Scheme handler in-flight tracking should also drain")
    }

    // MARK: - Setup helpers

    private struct Env {
        let node: IPFSNode
        let settings: SettingsStore
        let pool: EthereumRPCPool
        let resolver: ENSResolver
        let navContext: IpfsNavContext
        let handlerIpfs: IpfsSchemeHandler
        let handlerIpns: IpfsSchemeHandler
        let webView: WKWebView
        let delegate: NavCapture
    }

    private func makeEnv() async throws -> Env {
        let dataDir = makeTemporaryDataDir()
        let settings = SettingsStore(defaults: makeEphemeralDefaults())
        settings.ipfsGatewayTransport = .nativeFFI

        let node = IPFSNode()
        node.start(settings.ipfsConfig(dataDir: dataDir))
        guard await waitForNodeRunning(node) else {
            // Leak partial state so the failure doesn't trip the
            // back-deploy crash on the way out.
            Self.leakedDependencies.append(contentsOf: [node, settings] as [AnyObject])
            XCTFail("Node failed to start within \(Self.nodeStartTimeoutSeconds)s")
            throw XCTSkip("Node failed to start; cleanup tests can't proceed")
        }

        let pool = mainnetPool(settings: settings)
        let resolver = ENSResolver(pool: pool, settings: settings)
        let navContext = IpfsNavContext()

        let handlerIpfs = IpfsSchemeHandler(
            node: node, ensResolver: resolver, navContext: navContext, settings: settings
        )
        let handlerIpns = IpfsSchemeHandler(
            node: node, ensResolver: resolver, navContext: navContext, settings: settings
        )

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(handlerIpfs, forURLScheme: "ipfs")
        config.setURLSchemeHandler(handlerIpns, forURLScheme: "ipns")

        let webView = WKWebView(frame: .zero, configuration: config)
        let delegate = NavCapture()
        webView.navigationDelegate = delegate

        return Env(
            node: node,
            settings: settings,
            pool: pool,
            resolver: resolver,
            navContext: navContext,
            handlerIpfs: handlerIpfs,
            handlerIpns: handlerIpns,
            webView: webView,
            delegate: delegate
        )
    }

    private static func leak(_ env: Env) {
        leakedDependencies.append(contentsOf: [
            env.node, env.settings, env.pool, env.resolver, env.navContext,
            env.handlerIpfs, env.handlerIpns, env.webView, env.delegate,
        ] as [AnyObject])
    }

    // MARK: - Observation

    /// Parse `active_native_handles` out of the raw stats JSON. Returns
    /// `-1` if the snapshot is unavailable (node stopped) so an
    /// `XCTAssertEqual(_, 0)` will surface the missing-snapshot case
    /// distinctly from a leak.
    private func activeNativeHandles(node: IPFSNode) -> Int {
        guard let json = node.snapshotNativeGatewayStatsJSON(),
              let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = parsed["active_native_handles"] as? Int
        else { return -1 }
        return count
    }

    private func handlerInFlight(env: Env) -> Int {
        env.handlerIpfs.inFlightRequestCount + env.handlerIpns.inFlightRequestCount
    }

    /// Block the test until at least one native handle is active so
    /// the disturbance actually exercises the native cancel path
    /// rather than the ENS-resolution cancel path. Throws when the
    /// timeout fires; the test fails with a clear "request never
    /// started" diagnostic instead of a confusing 0-handles assertion.
    private func waitUntilNativeHandlesActive(env: Env) async throws {
        let deadline = Date(timeIntervalSinceNow: Self.nativeRequestStartTimeoutSeconds)
        while Date() < deadline {
            if activeNativeHandles(node: env.node) > 0 { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Native request never started within \(Self.nativeRequestStartTimeoutSeconds)s — ENS resolution likely timed out or the gateway didn't accept the request")
        throw XCTSkip("Cannot exercise cleanup path without an active native request")
    }

    /// Wait for handler in-flight tracking AND `active_native_handles`
    /// to both drain to 0. Uses `handlerInFlight` as the primary
    /// indicator because it covers all three pathways
    /// (pendingResolutions / active / activeNative).
    private func waitForInFlightQuiesce(env: Env) async {
        let deadline = Date(timeIntervalSinceNow: Self.cleanupSettleCapSeconds)
        while Date() < deadline {
            if handlerInFlight(env: env) == 0, activeNativeHandles(node: env.node) == 0 {
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
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

    private func makeTemporaryDataDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("freedom-cleanup-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeEphemeralDefaults() -> UserDefaults {
        let suite = "freedom.cleanup.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? .standard
    }
}

/// Local copy of the corpus harness's NavCapture. Both could be lifted
/// to a shared TestHelpers later (already on the /simplify follow-up
/// list); kept inline here so this PR doesn't grow a refactor.
@MainActor
private final class NavCapture: NSObject, WKNavigationDelegate {
    enum Outcome: Equatable {
        case didFinish
        case didFail(message: String)
        case timeout
    }

    private var continuation: CheckedContinuation<Outcome, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var fired = false

    func waitForOutcome(timeout: TimeInterval) async -> Outcome {
        await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
            self.continuation = cont
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.fire(.timeout) }
            }
        }
    }

    private func fire(_ outcome: Outcome) {
        guard !fired else { return }
        fired = true
        timeoutTask?.cancel()
        timeoutTask = nil
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
