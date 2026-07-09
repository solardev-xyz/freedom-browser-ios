import Foundation

/// Connection lifecycle of one openlv session, as surfaced to UI.
enum OpenLVEngineStatus: Equatable, Sendable {
    case connecting
    case connected
    case disconnected
    case failed(String)
}

/// Outcome of one JSON-RPC request from the remote browser. Mirrors the
/// wire envelope the browser's remote signer expects: `{result}` on
/// success, `{error: {code, message}}` with EIP-1193 codes (4001
/// user-reject, 4902 unrecognized chain, …) on failure. `result` must be
/// JSON-serializable (String / number / array / dictionary / NSNull).
enum OpenLVResponse {
    case result(Any)
    case error(code: Int, message: String)
}

/// Protocol seam for the openlv transport (open-lavatory spec 002).
///
/// An engine owns one session at a time: `start(uri:)` joins the session
/// encoded in an `openlv://` URI (the wallet/client role — Freedom
/// desktop is the host), incoming JSON-RPC requests surface through
/// `requestHandler`, and the handler's `OpenLVResponse` travels back over
/// the encrypted channel. Implementation #1 is `WebViewOpenLVEngine`
/// (hidden WKWebView running the upstream JS SDK); a native Swift engine
/// can slot in behind this same seam later without touching the
/// wallet-endpoint integration built on top.
@MainActor
protocol OpenLVSessionEngine: AnyObject {
    /// Answers every JSON-RPC request from the connected browser. Unset
    /// handler ⇒ the engine replies `-32603` so the peer never hangs.
    var requestHandler: ((_ method: String, _ params: [Any]) async -> OpenLVResponse)? { get set }

    /// Connection lifecycle events, delivered on the main actor.
    var statusHandler: ((OpenLVEngineStatus) -> Void)? { get set }

    /// Join the session encoded in `uri`. Throws only on engine-level
    /// failures (e.g. the runtime failed to boot); connection problems —
    /// bad URI, unreachable relay, peer never showing up — arrive as
    /// `.failed` through `statusHandler`, matching how they surface
    /// asynchronously in the underlying protocol.
    func start(uri: String) async throws

    /// Close the current session, if any. The engine stays usable for a
    /// subsequent `start(uri:)`.
    func stop()
}
