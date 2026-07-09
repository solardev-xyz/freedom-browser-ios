import WebKit
import XCTest
@testable import Freedom

/// Full-protocol test against the real desktop host: the vendored
/// openlv SDK in the hidden WKWebView ↔ local MQTT signaling ↔ WebRTC
/// ↔ a Chromium page running the same SDK in the host role (Node has
/// no WebRTC).
///
/// Needs the harness from the freedom-browser repo running on the Mac —
/// run via `scripts/openlv-e2e.sh`, which boots it and passes
/// `OPENLV_HARNESS_URL` through to this process. Skips otherwise, so
/// the normal suite stays offline.
///
/// The host sends the exact sequence a desktop signing job produces:
/// eth_requestAccounts → wallet_switchEthereumChain pre-flight →
/// personal_sign. The test answers with canned values (approval-sheet
/// routing is WP-R4b) and asserts the host recorded them verbatim —
/// proving envelopes, encryption, signaling, and transport end to end.
@MainActor
final class OpenLVHarnessTests: XCTestCase {
    private static let account = "0x1111111111111111111111111111111111111111"
    private static let signature = "0x" + String(repeating: "ab", count: 65)

    func testDesktopHostSessionEndToEnd() async throws {
        guard let base = ProcessInfo.processInfo.environment["OPENLV_HARNESS_URL"] else {
            throw XCTSkip("OPENLV_HARNESS_URL not set — run scripts/openlv-e2e.sh")
        }

        let uri = try await fetchURI(base: base)
        XCTAssertTrue(uri.hasPrefix("openlv://"), "harness returned a non-openlv URI: \(uri)")

        let engine = WebViewOpenLVEngine()
        defer {
            engine.webView.removeFromSuperview()
            engine.stop()
        }
        attachToKeyWindow(engine.webView)

        var statuses: [OpenLVEngineStatus] = []
        engine.statusHandler = { statuses.append($0) }
        engine.requestHandler = { method, _ in
            switch method {
            case "eth_requestAccounts":
                return .result([Self.account])
            case "wallet_switchEthereumChain":
                return .result(NSNull())
            case "personal_sign":
                return .result(Self.signature)
            default:
                return .error(code: 4200, message: "Method not supported: \(method)")
            }
        }

        try await engine.start(uri: uri)

        let state = try await pollUntilDone(base: base, timeout: 90)
        XCTAssertNil(state["error"] as? String)
        XCTAssertTrue(statuses.contains(.connected), "engine never reported connected; saw \(statuses)")

        let exchanges = state["exchanges"] as? [[String: Any]] ?? []
        XCTAssertEqual(exchanges.map { $0["method"] as? String },
                       ["eth_requestAccounts", "wallet_switchEthereumChain", "personal_sign"])

        func response(_ index: Int) -> [String: Any]? {
            exchanges.indices.contains(index) ? exchanges[index]["response"] as? [String: Any] : nil
        }
        XCTAssertEqual(response(0)?["result"] as? [String], [Self.account])
        XCTAssertTrue(response(1)?.keys.contains("result") ?? false,
                      "chain switch should resolve with a (null) result, got \(String(describing: response(1)))")
        XCTAssertEqual(response(2)?["result"] as? String, Self.signature)
    }

    // MARK: - Harness control surface

    private func fetchJSON(_ url: URL) async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func fetchURI(base: String) async throws -> String {
        let payload = try await fetchJSON(XCTUnwrap(URL(string: "\(base)/uri")))
        return try XCTUnwrap(payload["uri"] as? String, "harness has no session URI yet")
    }

    private func pollUntilDone(base: String, timeout: TimeInterval) async throws -> [String: Any] {
        let url = try XCTUnwrap(URL(string: "\(base)/state"))
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let state = try await fetchJSON(url)
            let phase = state["phase"] as? String
            if phase == "done" || phase == "error" { return state }
            if Date() > deadline {
                XCTFail("harness never reached done; last state: \(state)")
                return state
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}
