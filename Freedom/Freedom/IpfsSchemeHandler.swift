import Foundation
import IPFSKit
import os.log
import WebKit

/// Subsystem-shared with `NativeGatewayDispatcher` so a single
/// `log stream --predicate 'subsystem == "com.browser.Freedom.native"'`
/// catches the full event sequence for a native FFI request.
private let nativeLogger = Logger(subsystem: "com.browser.Freedom.native", category: "sink")

/// Mutable per-tab state describing the current top-level
/// `ipfs://` / `ipns://` navigation, if any. Owned by `BrowserTab`,
/// shared with that tab's two scheme handlers (one for each scheme).
/// The handlers stamp correlation headers on outgoing requests so
/// the Rust gateway can group subresource progress events under
/// their parent navigation in `progressSnapshot`.
///
/// `topLevelPath` is the gateway-style path
/// (`/ipfs/<cid>/...` or `/ipns/<name>/...`) of the page WebKit is
/// loading right now. `rootRequestID` is filled in by the scheme
/// handler when it sees the request whose path matches
/// `topLevelPath` — that id then becomes
/// `X-Freedom-Parent-Request-ID` for every subresource.
@MainActor
final class IpfsNavContext {
    private(set) var topLevelPath: String?
    private(set) var rootRequestID: UInt64?

    func begin(topLevelPath: String) {
        self.topLevelPath = topLevelPath
        rootRequestID = nil
    }

    func end() {
        topLevelPath = nil
        rootRequestID = nil
    }

    /// Called by the scheme handler when it sees the request whose
    /// path matches `topLevelPath`. Subsequent subresource requests
    /// for the same navigation stamp this id as
    /// `X-Freedom-Parent-Request-ID`.
    func recordRootRequestID(_ id: UInt64) {
        rootRequestID = id
    }
}

/// Custom scheme handler for `ipfs://` and `ipns://`. Translates each
/// request the WKWebView issues against either scheme into a native
/// FFI request against the running Rust IPFS reader
/// (`freedom_ipfs_gateway_request_*`) and streams the response back
/// through the WKURLSchemeTask. There is no loopback HTTP gateway and
/// no URLSession — the request is driven directly over the FFI, with
/// body bytes pulled off the node's shared event multiplexer.
///
/// Notes:
/// 1. Forwards selected request headers (notably `Range`) through to
///    the gateway so WebKit's media loaders can issue byte-range
///    requests.
/// 2. Streams response bytes incrementally so large responses don't
///    get buffered whole into RAM.
/// 3. Stamps `request_id` / `parent_request_id` / `top_level_path`
///    correlation fields so the Rust gateway can group subresource
///    progress events under their parent navigation.
@MainActor
final class IpfsSchemeHandler: NSObject, WKURLSchemeHandler {
    /// Permissive CORS so cross-content `fetch('ipfs://<cid>/')` from an
    /// `ipfs://` page works, matching desktop's `corsEnabled: true`
    /// scheme registration.
    static let corsResponseHeaders: [String: String] = [
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Range",
        "Access-Control-Max-Age": "600",
        "Access-Control-Expose-Headers": "Content-Length, Content-Range",
    ]

    /// Weak ref — the node is owned by `FreedomApp` and outlives any
    /// individual tab. A weak ref keeps tabs from extending the node's
    /// lifetime past app teardown.
    private weak var node: IPFSNode?
    /// Weak ref — the navigation context lives on `BrowserTab`. When
    /// the tab is gone the handler still works, just without
    /// correlation grouping.
    private weak var navContext: IpfsNavContext?
    private let ensResolver: any ENSResolving
    /// Tracks scheme tasks whose ENS resolution is in flight. The
    /// native request isn't started until resolution completes — so
    /// `stop(_:)` needs a separate place to mark the scheme task
    /// cancelled before any `activeNative` entry exists.
    private var pendingResolutions: [ObjectIdentifier: PendingResolution] = [:]
    fileprivate var activeNative: [UInt64: NativePending] = [:]

    init(
        node: IPFSNode,
        ensResolver: any ENSResolving,
        navContext: IpfsNavContext? = nil
    ) {
        self.node = node
        self.ensResolver = ensResolver
        self.navContext = navContext
        super.init()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let originalURL = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }

        // Short-circuit OPTIONS preflights at the handler. The Rust
        // reader serves verified GET/HEAD only; a passthrough OPTIONS
        // would error out and the actual request would never run.
        if (task.request.httpMethod ?? "GET").uppercased() == "OPTIONS" {
            let response = Self.sameOriginResponse(url: originalURL, status: 204, headers: [:])!
            task.didReceive(response)
            task.didReceive(Data()) // WKURLSchemeTask contract: body call required before didFinish
            task.didFinish()
            return
        }

        // ENS-named host (`ipfs://vitalik.eth/...`): resolve via ENS,
        // verify codec, then form the gateway path against the
        // resolved CID. Non-`.eth` hosts continue straight to the
        // Rust gateway, which handles CID hosts and DNSLink/IPNS names.
        if let name = originalURL.ensName {
            startWithENSResolution(originalURL: originalURL, name: name, task: task)
            return
        }

        guard let urlGatewayPath = Self.gatewayStylePath(for: originalURL) else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        startUpstreamFetch(
            originalURL: originalURL,
            gatewayPath: urlGatewayPath,
            sourceRequest: task.request,
            task: task
        )
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        if let pending = pendingResolutions.removeValue(forKey: ObjectIdentifier(task)) {
            pending.cancelled = true
            return
        }
        cancelActiveNative(matching: task)
    }

    /// Count of in-flight requests. Useful for test teardown drain
    /// loops; production code reacts per-task via `webView(_:stop:)`
    /// and doesn't need an aggregate.
    var inFlightRequestCount: Int {
        activeNative.count + pendingResolutions.count
    }

    /// Synchronously cancel every in-flight request. After this
    /// returns, no further native dispatcher callback will touch a
    /// `WKURLSchemeTask` on this handler. Intended for test teardown
    /// where the WKWebView and scheme handlers are about to be
    /// deallocated while subresource requests are still racing —
    /// production tabs drain through `webView(_:stop:)` per task.
    func invalidate() {
        for pending in pendingResolutions.values {
            pending.cancelled = true
        }
        pendingResolutions.removeAll()
        for (id, pending) in activeNative {
            pending.markTerminated()
            node?.unregisterNativeGatewaySink(handleID: id)
            _ = pending.handle.cancel()
            _ = pending.handle.free()
        }
        activeNative.removeAll()
    }

    // MARK: - ENS resolution

    private func startWithENSResolution(originalURL: URL, name: String, task: WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        let pending = PendingResolution()
        pendingResolutions[key] = pending
        Task { [weak self] in
            guard let self else { return }
            defer { self.pendingResolutions.removeValue(forKey: key) }
            do {
                let resolved = try await self.ensResolver.resolveContent(name)
                guard !pending.cancelled else { return }
                self.handleENSResolved(originalURL: originalURL, resolved: resolved, task: task)
            } catch {
                guard !pending.cancelled else { return }
                Self.deliverErrorPage(
                    originalURL: originalURL,
                    statusCode: 502,
                    body: SchemeHandlerErrorPage.render(.resolutionFailed(
                        name: name,
                        message: ENSErrorFormatting.describe(error)
                    )),
                    task: task
                )
            }
        }
    }

    private func handleENSResolved(originalURL: URL, resolved: ENSResolvedContent, task: WKURLSchemeTask) {
        let requestScheme = originalURL.scheme?.lowercased() ?? ""
        let expected: ENSContentCodec
        switch requestScheme {
        case "ipfs": expected = .ipfs
        case "ipns": expected = .ipns
        default:
            // Handler is only registered for ipfs/ipns; any other
            // scheme reaching here is a wiring bug rather than a
            // user-visible codec mismatch.
            task.didFailWithError(URLError(.badURL))
            return
        }
        guard resolved.codec == expected else {
            Self.deliverErrorPage(
                originalURL: originalURL,
                statusCode: 404,
                body: SchemeHandlerErrorPage.render(.codecMismatch(
                    requestedScheme: requestScheme,
                    resolvedScheme: resolved.codec.scheme,
                    name: resolved.name
                )),
                task: task
            )
            return
        }
        guard let gatewayPath = Self.gatewayStylePath(for: originalURL, resolvedTo: resolved.contentRef) else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        startUpstreamFetch(
            originalURL: originalURL,
            gatewayPath: gatewayPath,
            sourceRequest: task.request,
            task: task
        )
    }

    /// Synthesize a 4xx/5xx HTML response on a `WKURLSchemeTask`. Used
    /// by both the ENS error paths and the native FFI failure paths.
    /// Must only be called before any other `didReceive(response:)` —
    /// WK rejects a second response mid-stream.
    @MainActor
    static func deliverErrorPage(
        originalURL: URL,
        statusCode: Int,
        body: String,
        task: WKURLSchemeTask
    ) {
        let data = Data(body.utf8)
        let response = sameOriginResponse(
            url: originalURL,
            status: statusCode,
            headers: [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Length": "\(data.count)",
            ]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    /// Classify an `Error` from the native FFI flow into the page kind
    /// we should render in place of WK's stock error page. Returns
    /// `nil` for errors WK already handles well — notably
    /// `URLError(.cancelled)`, which WK silently suppresses (no error
    /// page; the right UX for user-initiated cancels). Callers fall
    /// through to `didFailWithError(_:)` in the `nil` case.
    nonisolated static func errorPageKind(
        for error: Error,
        originalURL: URL
    ) -> SchemeHandlerErrorPage.Kind? {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return nil
            case .cannotConnectToHost:
                return .nodeUnavailable(url: originalURL.absoluteString)
            default:
                return .retrievalFailed(
                    url: originalURL.absoluteString,
                    code: nil,
                    message: urlError.localizedDescription
                )
            }
        }
        if let ipfsError = error as? IPFSError, case .notRunning = ipfsError {
            return .nodeUnavailable(url: originalURL.absoluteString)
        }
        let ns = error as NSError
        if ns.domain == nativeErrorDomain {
            return .retrievalFailed(
                url: originalURL.absoluteString,
                code: ns.userInfo[nativeErrorCodeKey] as? String,
                message: ns.userInfo[NSLocalizedDescriptionKey] as? String
            )
        }
        return .retrievalFailed(
            url: originalURL.absoluteString,
            code: nil,
            message: error.localizedDescription
        )
    }

    /// Classify `error` and, if classifiable, deliver the synthesized
    /// 502 HTML page. Returns `true` iff a page was rendered (so the
    /// caller can fall through to `didFailWithError(_:)` on `false`
    /// without re-classifying). Must only be called pre-response — WK
    /// rejects a second `didReceive(response:)` mid-stream.
    @MainActor
    static func tryDeliverErrorPage(
        for error: Error,
        originalURL: URL,
        task: WKURLSchemeTask
    ) -> Bool {
        guard let kind = errorPageKind(for: error, originalURL: originalURL) else {
            return false
        }
        deliverErrorPage(
            originalURL: originalURL,
            statusCode: nativeFailureStatus,
            body: SchemeHandlerErrorPage.render(kind),
            task: task
        )
        return true
    }

    // MARK: - Upstream fetch (shared by CID-host and ENS-resolved paths)

    private func startUpstreamFetch(
        originalURL: URL,
        gatewayPath: String,
        sourceRequest: URLRequest,
        task: WKURLSchemeTask
    ) {
        startNativeUpstream(
            originalURL: originalURL,
            gatewayPath: gatewayPath,
            sourceRequest: sourceRequest,
            task: task
        )
    }

    /// Compute the gateway-style path for an `ipfs://` / `ipns://`
    /// URL. Returns `/ipfs/<cid>/<path>` or `/ipns/<name>/<path>`,
    /// with the nested-fetch passthrough: when a JS app on an
    /// `ipfs://` origin issues a relative `/ipfs/<other-cid>/...`,
    /// that arrives here as `ipfs://<this-cid>/ipfs/<other-cid>/...`
    /// — we pass the inner path through unchanged so the gateway
    /// serves the referenced content rather than nesting CIDs.
    /// Returns `nil` for non-ipfs URLs.
    ///
    /// When `resolvedTo` is non-nil, the URL's host (an ENS name) is
    /// replaced by the resolved CID for the non-nested branch — so
    /// `ipfs://vitalik.eth/foo` with `resolvedTo: <cid>` becomes
    /// `/ipfs/<cid>/foo`. The nested-fetch branch is unaffected.
    static func gatewayStylePath(for url: URL, resolvedTo contentRef: String? = nil) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "ipfs" || scheme == "ipns",
              let host = url.host else { return nil }
        // `URL.path` strips trailing slashes; the percent-encoded
        // accessor preserves them, so directory-shaped requests reach
        // the Rust gateway as `/<scheme>/<ref>/foo/` rather than the
        // slash-stripped form.
        let raw = url.path(percentEncoded: false)
        let path = raw.isEmpty ? "/" : raw
        if path.hasPrefix("/ipfs/") || path.hasPrefix("/ipns/") {
            return path
        }
        return "/\(scheme)/\(contentRef ?? host)\(path)"
    }

    /// Build an `HTTPURLResponse` whose URL is the original `ipfs://`
    /// / `ipns://` (so WebKit treats it as same-origin with the page)
    /// and whose headers include the permissive CORS overlay so
    /// cross-content `ipfs://<other-cid>/` fetches from other
    /// `ipfs://` pages succeed.
    nonisolated static func sameOriginResponse(
        url: URL,
        status: Int,
        headers: [String: String]
    ) -> HTTPURLResponse? {
        var merged = headers
        merged.merge(corsResponseHeaders) { _, new in new }
        return HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: merged
        )
    }

    // MARK: - Native FFI flow

    /// 64 KiB sits in the 32-256 KiB band recommended by the
    /// native-gateway handoff.
    fileprivate static let nativeReadBufferBytes = 64 * 1024

    fileprivate static let nativeEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    fileprivate static let nativeDecoder = JSONDecoder()

    private func startNativeUpstream(
        originalURL: URL,
        gatewayPath: String,
        sourceRequest: URLRequest,
        task: WKURLSchemeTask
    ) {
        guard let node else {
            failNativeStart(error: URLError(.cannotConnectToHost), originalURL: originalURL, task: task)
            return
        }

        let requestID = node.nextGatewayRequestID()
        var parentRequestID: UInt64?
        var topLevelPath: String?
        if let context = navContext, let topPath = context.topLevelPath {
            topLevelPath = topPath
            if gatewayPath == topPath {
                context.recordRootRequestID(requestID)
            } else {
                parentRequestID = context.rootRequestID
            }
        }

        let json: String
        do {
            json = try Self.buildNativeRequestJSON(
                method: sourceRequest.httpMethod ?? "GET",
                gatewayPath: gatewayPath,
                headers: sourceRequest.allHTTPHeaderFields ?? [:],
                requestID: requestID,
                parentRequestID: parentRequestID,
                topLevelPath: topLevelPath
            )
        } catch {
            failNativeStart(error: error, originalURL: originalURL, task: task)
            return
        }

        do {
            let (handle, pending) = try node.startNativeGatewayRequest(json: json) { handle in
                NativePending(
                    schemeTask: task,
                    originalURL: originalURL,
                    handle: handle,
                    owner: self
                )
            }
            activeNative[handle.id] = pending
            nativeLogger.info(
                "start handle=\(handle.id, privacy: .public) path=\(gatewayPath, privacy: .public) requestID=\(requestID, privacy: .public) parent=\(parentRequestID.map(String.init) ?? "-", privacy: .public)"
            )
        } catch {
            nativeLogger.error("start failed path=\(gatewayPath, privacy: .public) error=\(String(describing: error), privacy: .public)")
            failNativeStart(error: error, originalURL: originalURL, task: task)
        }
    }

    private func failNativeStart(error: Error, originalURL: URL, task: WKURLSchemeTask) {
        if !Self.tryDeliverErrorPage(for: error, originalURL: originalURL, task: task) {
            task.didFailWithError(error)
        }
    }

    /// Synchronously tear down any native request whose scheme task
    /// matches `task`. Marks the pending terminated (silences the
    /// sink), tombstones the dispatcher registration, cancels and
    /// frees the Rust handle. Any events that fired between start and
    /// here land in the dispatcher's tombstone path and get dropped.
    fileprivate func cancelActiveNative(matching task: WKURLSchemeTask) {
        let keys = activeNative.compactMap { $0.value.schemeTask === task ? $0.key : nil }
        for id in keys {
            guard let pending = activeNative.removeValue(forKey: id) else { continue }
            nativeLogger.info("cancel handle=\(id, privacy: .public) reason=webViewStop")
            pending.markTerminated()
            node?.unregisterNativeGatewaySink(handleID: id)
            _ = pending.handle.cancel()
            _ = pending.handle.free()
        }
    }

    /// Returns a structured error from Rust's response metadata, but
    /// only if the metadata's own state is terminal. See
    /// `NativeResponseMetadata.State.isTerminal`.
    nonisolated fileprivate static func nativeMetadataTerminalError(
        handle: any NativeGatewayHandleProtocol
    ) -> Error? {
        guard let json = try? handle.responseJSON(timeoutMilliseconds: 0),
              let meta = try? decodeNativeResponseMetadata(json),
              meta.state.isTerminal
        else { return nil }
        return nativeError(from: meta)
    }

    nonisolated fileprivate static func nativeReadError(
        handle: any NativeGatewayHandleProtocol,
        status: FreedomIpfsNativeGatewayReadStatus
    ) -> Error {
        if let metaError = nativeMetadataTerminalError(handle: handle) {
            return metaError
        }
        switch status {
        case .cancelled:     return URLError(.cancelled)
        case .failed:        return URLError(.badServerResponse)
        case .invalidHandle: return URLError(.badServerResponse)
        default:             return URLError(.unknown)
        }
    }

    /// NSError domain + userInfo key used to ferry the Rust gateway's
    /// structured error code/message from `nativeError(from:)` (the
    /// producer) to `errorPageKind(for:)` (the consumer). String
    /// literals lived in both sites previously; promoted here so the
    /// producer/consumer pair can't drift.
    fileprivate static let nativeErrorDomain = "FreedomIPFSNativeGateway"
    fileprivate static let nativeErrorCodeKey = "FreedomIPFSNativeErrorCode"
    /// Status code for the synthesized 5xx HTML page on a native FFI
    /// failure. Bad Gateway maps cleanly to "the upstream IPFS gateway
    /// couldn't fulfill this request" and matches what the ENS
    /// resolution-failed branch uses.
    fileprivate static let nativeFailureStatus = 502

    nonisolated fileprivate static func nativeError(from metadata: NativeResponseMetadata) -> Error {
        // WebKit treats `URLError(.cancelled)` as a user-initiated
        // cancel (no error page shown). A cancelled-state structured
        // NSError would render a "request cancelled" page for every
        // back-button / new-navigation cancel — wrong UX.
        if metadata.state == .cancelled {
            return URLError(.cancelled)
        }
        let message = metadata.error?.message ?? "native gateway request \(metadata.state.rawValue)"
        let code = metadata.error?.code ?? "unknown"
        return NSError(
            domain: nativeErrorDomain,
            code: -1,
            userInfo: [
                NSLocalizedDescriptionKey: message,
                nativeErrorCodeKey: code,
            ]
        )
    }

    // MARK: - Native request/response JSON

    private struct NativeRequestPayload: Encodable, Equatable {
        let method: String
        let path: String
        let headers: [Header]
        let requestID: UInt64?
        let parentRequestID: UInt64?
        let topLevelPath: String?

        enum CodingKeys: String, CodingKey {
            case method, path, headers
            case requestID = "request_id"
            case parentRequestID = "parent_request_id"
            case topLevelPath = "top_level_path"
        }

        struct Header: Encodable, Equatable {
            let name: String
            let value: String
        }
    }

    struct NativeResponseMetadata: Decodable, Equatable {
        enum State: String, Decodable {
            case pending, streaming, completed, cancelled, failed

            /// Rust only populates the structured error fields once the
            /// request has reached a terminal state — using metadata for
            /// errors in any other state produces misleading messages
            /// like "native gateway request pending".
            var isTerminal: Bool { self == .failed || self == .cancelled }
        }

        let state: State
        let status: Int?
        let headers: [Header]?
        let completed: Bool?
        let cancelled: Bool?
        let error: ErrorPayload?

        struct Header: Decodable, Equatable {
            let name: String
            let value: String
        }

        struct ErrorPayload: Decodable, Equatable {
            let code: String?
            let message: String?
        }
    }

    /// Build the request JSON the Rust native gateway expects.
    /// `X-Freedom-*` correlation headers are stamped by Rust from the
    /// top-level `request_id` / `parent_request_id` / `top_level_path`
    /// fields, so we omit them from `headers` to avoid a double-stamp.
    nonisolated static func buildNativeRequestJSON(
        method: String,
        gatewayPath: String,
        headers: [String: String],
        requestID: UInt64?,
        parentRequestID: UInt64?,
        topLevelPath: String?
    ) throws -> String {
        var forwarded = headers
        forwarded.removeValue(forKey: "Host")
        forwarded.removeValue(forKey: "host")
        forwarded.removeValue(forKey: "X-Freedom-Request-ID")
        forwarded.removeValue(forKey: "X-Freedom-Parent-Request-ID")
        forwarded.removeValue(forKey: "X-Freedom-Top-Level-Path")
        let payload = NativeRequestPayload(
            method: method.uppercased(),
            path: gatewayPath,
            headers: forwarded
                .map { NativeRequestPayload.Header(name: $0.key, value: $0.value) }
                .sorted(by: { $0.name.lowercased() < $1.name.lowercased() }),
            requestID: requestID,
            parentRequestID: parentRequestID,
            topLevelPath: topLevelPath
        )
        let data = try nativeEncoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func decodeNativeResponseMetadata(_ json: String) throws -> NativeResponseMetadata {
        try nativeDecoder.decode(NativeResponseMetadata.self, from: Data(json.utf8))
    }
}

/// Protocol seam for `NativePending`'s back-pointer to the scheme
/// handler. Returns `true` iff the handle was still registered (so a
/// `webView(_:stop:)` racing in mid-delivery is the same observable
/// state as "already terminated"). Tests stub this so they can drive
/// `NativePending` without standing up a real `IpfsSchemeHandler`
/// (which would need a real `IPFSNode`).
@MainActor
protocol NativePendingOwner: AnyObject {
    func nativePendingClaimDelivery(handleID: UInt64) -> Bool
    func nativePendingRemove(handleID: UInt64) -> Bool
}

extension IpfsSchemeHandler: NativePendingOwner {
    func nativePendingClaimDelivery(handleID: UInt64) -> Bool {
        activeNative[handleID] != nil
    }

    @discardableResult
    func nativePendingRemove(handleID: UInt64) -> Bool {
        activeNative.removeValue(forKey: handleID) != nil
    }
}

/// Sink for the node-level event multiplexer. Receives events on the
/// `NativeGatewayDispatcher` worker thread, does the FFI work there,
/// and hops to main only for WK callbacks. Owned by `IpfsSchemeHandler`
/// via the `activeNative` dict; removed on terminal event or on
/// `webView(_:stop:)`.
final class NativePending: NativeRequestSink, @unchecked Sendable {
    let schemeTask: WKURLSchemeTask
    let originalURL: URL
    let handle: any NativeGatewayHandleProtocol
    weak var owner: (any NativePendingOwner)?

    private let stateLock = NSLock()
    private var responseDelivered = false
    private var terminated = false

    init(
        schemeTask: WKURLSchemeTask,
        originalURL: URL,
        handle: any NativeGatewayHandleProtocol,
        owner: any NativePendingOwner
    ) {
        self.schemeTask = schemeTask
        self.originalURL = originalURL
        self.handle = handle
        self.owner = owner
    }

    /// Called by the owner on `webView(_:stop:)` to silence any future
    /// sink processing. Idempotent. Caller is responsible for
    /// cancel/free; this only sets the flag.
    func markTerminated() {
        stateLock.lock()
        terminated = true
        stateLock.unlock()
    }

    func nativeRequestReceivedEvent(_ event: FreedomIpfsNativeGatewayEvent) {
        // Defense-in-depth: the dispatcher routes by handle id, but a
        // mis-routed event would otherwise free `self.handle` for a
        // request that isn't ours.
        guard event.requestHandle == handle.id else { return }
        if isTerminated { return }
        let flags = event.events
        if flags.contains(.failed) || flags.contains(.cancelled) || flags.contains(.handleFreed) {
            terminate(with: nativeTerminalError(flags: flags))
            return
        }
        if flags.contains(.responseReady) {
            deliverResponseIfNeeded()
        }
        if flags.contains(.bodyReady) || flags.contains(.end) {
            drainBody()
        }
    }

    private var isTerminated: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return terminated
    }

    private func deliverResponseIfNeeded() {
        stateLock.lock()
        if responseDelivered || terminated {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        let metadata: IpfsSchemeHandler.NativeResponseMetadata
        do {
            let json = try handle.responseJSON(timeoutMilliseconds: 0)
            metadata = try IpfsSchemeHandler.decodeNativeResponseMetadata(json)
        } catch {
            terminate(with: error)
            return
        }

        switch metadata.state {
        case .failed, .cancelled:
            terminate(with: IpfsSchemeHandler.nativeError(from: metadata))
            return
        case .pending:
            // metadata not actually ready despite the event — wait for
            // the next responseReady tick
            return
        case .streaming, .completed:
            break
        }

        guard let status = metadata.status else {
            terminate(with: URLError(.badServerResponse))
            return
        }

        let headers = Dictionary(
            (metadata.headers ?? []).map { ($0.name, $0.value) },
            uniquingKeysWith: { _, new in new }
        )
        guard let response = IpfsSchemeHandler.sameOriginResponse(
            url: originalURL,
            status: status,
            headers: headers
        ) else {
            terminate(with: URLError(.badServerResponse))
            return
        }

        stateLock.lock()
        if terminated {
            stateLock.unlock()
            return
        }
        responseDelivered = true
        stateLock.unlock()

        nativeLogger.info(
            "response handle=\(self.handle.id, privacy: .public) status=\(status, privacy: .public)"
        )
        deliverOnMain { $0.didReceive(response) }
    }

    private func drainBody() {
        stateLock.lock()
        if !responseDelivered || terminated {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        var buffer = [UInt8](
            unsafeUninitializedCapacity: IpfsSchemeHandler.nativeReadBufferBytes
        ) { _, count in
            count = IpfsSchemeHandler.nativeReadBufferBytes
        }

        while !isTerminated {
            let result: FreedomIpfsNativeGatewayReadResult
            do {
                result = try buffer.withUnsafeMutableBytes { bytes in
                    try handle.read(into: bytes, timeoutMilliseconds: 0)
                }
            } catch {
                terminate(with: error)
                return
            }
            switch result.status {
            case .bytes:
                if result.bytesRead > 0 {
                    let chunk = buffer.withUnsafeBytes { raw in
                        Data(bytes: raw.baseAddress!, count: result.bytesRead)
                    }
                    nativeLogger.debug(
                        "chunk handle=\(self.handle.id, privacy: .public) bytes=\(result.bytesRead, privacy: .public)"
                    )
                    deliverOnMain { $0.didReceive(chunk) }
                }
            case .pending:
                return
            case .end:
                terminate(with: nil)
                return
            case .cancelled, .failed, .invalidHandle:
                terminate(
                    with: IpfsSchemeHandler.nativeReadError(handle: handle, status: result.status)
                )
                return
            }
        }
    }

    private func nativeTerminalError(flags: FreedomIpfsNativeGatewayEventFlags) -> Error {
        if let metaError = IpfsSchemeHandler.nativeMetadataTerminalError(handle: handle) {
            return metaError
        }
        if flags.contains(.cancelled) {
            return URLError(.cancelled)
        }
        return URLError(.badServerResponse)
    }

    /// `error == nil` ⇒ `didFinish`; pre-response classifiable error
    /// ⇒ 502 HTML page; else ⇒ `didFailWithError`. Mid-stream failures
    /// can't render a page because WK rejects a second
    /// `didReceive(response:)`.
    private func terminate(with error: Error?) {
        stateLock.lock()
        if terminated {
            stateLock.unlock()
            return
        }
        terminated = true
        // Snapshot under the lock; main hop must see the pre-terminate value.
        let responseAlreadyDelivered = responseDelivered
        stateLock.unlock()

        _ = handle.free()

        let id = handle.id
        if let error {
            nativeLogger.info(
                "terminate handle=\(id, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        } else {
            nativeLogger.info("finish handle=\(id, privacy: .public)")
        }
        let originalURL = self.originalURL
        DispatchQueue.main.async { [weak self, weak owner] in
            MainActor.assumeIsolated {
                guard let self, let owner else { return }
                guard owner.nativePendingRemove(handleID: id) else { return }
                guard let error else {
                    self.schemeTask.didFinish()
                    return
                }
                if responseAlreadyDelivered ||
                    !IpfsSchemeHandler.tryDeliverErrorPage(
                        for: error,
                        originalURL: originalURL,
                        task: self.schemeTask
                    ) {
                    self.schemeTask.didFailWithError(error)
                }
            }
        }
    }

    /// Hop to main and run `body` on the scheme task — non-terminal,
    /// keeps the entry in `activeNative`. `webView(_:stop:)` removes
    /// the entry before cancelling, so any delivery racing in after
    /// stop short-circuits via the containment check.
    private func deliverOnMain(_ body: @escaping @MainActor (WKURLSchemeTask) -> Void) {
        DispatchQueue.main.async { [weak self, weak owner] in
            MainActor.assumeIsolated {
                guard let self, let owner else { return }
                guard owner.nativePendingClaimDelivery(handleID: self.handle.id) else { return }
                body(self.schemeTask)
            }
        }
    }
}
