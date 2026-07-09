import WebKit
import XCTest
@testable import Freedom

/// Exercises the hidden-WKWebView openlv engine against its real shell
/// page (`OpenLVShell.html` + `OpenLVShim.js` + `openlv.iife.js`) — no
/// network, no signaling relay. The shim exposes the same
/// `handleRequest` the openlv session would call, so the tests drive
/// the full JS↔native round trip: shim promise → script message →
/// native `requestHandler` → `BridgeReplyChannel` reply → shim promise
/// resolution.
@MainActor
final class WebViewOpenLVEngineTests: XCTestCase {
    private var engine: WebViewOpenLVEngine!

    override func setUp() async throws {
        engine = WebViewOpenLVEngine()
        attachToKeyWindow(engine.webView)
    }

    override func tearDown() async throws {
        engine.webView.removeFromSuperview()
        engine.stop()
        engine = nil
    }

    /// Collects messages the test page posts to a dedicated side-channel
    /// handler, so tests can observe shim-side promise resolutions.
    private final class TestSink: NSObject, WKScriptMessageHandler {
        var messages: [Any] = []
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            messages.append(message.body)
        }
    }

    private func installSink() -> TestSink {
        let sink = TestSink()
        engine.webView.configuration.userContentController.add(sink, name: "openlvTest")
        return sink
    }

    private func waitFor(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 10,
        message: String
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(message)") }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Shell boot

    func testShellLoadsAndSignalsReady() async throws {
        try await engine.waitUntilReady()
    }

    // MARK: - Request round trips

    func testRequestRoundTripDeliversResult() async throws {
        try await engine.waitUntilReady()
        let sink = installSink()

        var received: (method: String, params: [Any])?
        engine.requestHandler = { method, params in
            received = (method, params)
            return .result(["0x1111111111111111111111111111111111111111"])
        }

        engine.webView.evaluateJavaScript(
            """
            window.__freedomOpenLV.request({method: 'eth_requestAccounts', params: []})
              .then(r => window.webkit.messageHandlers.openlvTest.postMessage(r));
            """,
            completionHandler: nil
        )

        await waitFor({ !sink.messages.isEmpty }, message: "shim promise never resolved")
        XCTAssertEqual(received?.method, "eth_requestAccounts")
        XCTAssertEqual(received?.params.count, 0)

        let envelope = sink.messages.first as? [String: Any]
        XCTAssertEqual(envelope?["result"] as? [String], ["0x1111111111111111111111111111111111111111"])
        XCTAssertNil(envelope?["error"])
    }

    func testRequestRoundTripDeliversError() async throws {
        try await engine.waitUntilReady()
        let sink = installSink()

        engine.requestHandler = { _, _ in .error(code: 4001, message: "User rejected the request.") }

        engine.webView.evaluateJavaScript(
            """
            window.__freedomOpenLV.request({method: 'personal_sign', params: ['0xdead', '0xbeef']})
              .then(r => window.webkit.messageHandlers.openlvTest.postMessage(r));
            """,
            completionHandler: nil
        )

        await waitFor({ !sink.messages.isEmpty }, message: "shim promise never resolved")
        let envelope = sink.messages.first as? [String: Any]
        let error = envelope?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, 4001)
        XCTAssertEqual(error?["message"] as? String, "User rejected the request.")
        XCTAssertNil(envelope?["result"])
    }

    func testRequestWithoutHandlerReturnsInternalError() async throws {
        try await engine.waitUntilReady()
        let sink = installSink()

        engine.webView.evaluateJavaScript(
            """
            window.__freedomOpenLV.request({method: 'eth_chainId', params: []})
              .then(r => window.webkit.messageHandlers.openlvTest.postMessage(r));
            """,
            completionHandler: nil
        )

        await waitFor({ !sink.messages.isEmpty }, message: "shim promise never resolved")
        let error = (sink.messages.first as? [String: Any])?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32603)
    }

    // MARK: - Session start failures (no network involved)

    func testStartWithInvalidURIReportsFailedStatus() async throws {
        var statuses: [OpenLVEngineStatus] = []
        engine.statusHandler = { statuses.append($0) }

        try await engine.start(uri: "openlv://not-a-valid-session-uri")

        await waitFor(
            { statuses.contains { if case .failed = $0 { return true }; return false } },
            message: "no failed status for invalid URI"
        )
    }

    func testStartWithNonMqttProtocolReportsFailedStatus() async throws {
        var statuses: [OpenLVEngineStatus] = []
        engine.statusHandler = { statuses.append($0) }

        // Well-formed session parameters, but a signaling protocol the
        // shim doesn't support — must fail fast, before touching network.
        let uri = "openlv://AAAAAAAAAAAAAAAA@1?h=0011223344556677&k=00112233445566778899aabbccddeeff&p=ntfy&s=ntfy.sh"
        try await engine.start(uri: uri)

        await waitFor(
            { statuses.contains { if case .failed(let m) = $0 { return m.contains("ntfy") }; return false } },
            message: "no failed status naming the unsupported protocol"
        )
    }
}
