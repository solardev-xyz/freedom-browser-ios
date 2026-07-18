import CryptoKit
import Foundation

/// One node-side receive pipeline: a WebSocket to the embedded ant
/// gateway's `GET /gsoc/subscribe/{address}` or `GET /pss/subscribe/{topic}`,
/// delivering each decoded message as a binary frame. Mirrors desktop's
/// `openSubscriptionSocket` semantics:
///
/// - **Establishment**: the node sends nothing on success and refuses
///   quickly on failure, so "open + stayed open for 500 ms" counts as
///   established.
/// - **Close 1013 (try again later) before establishment** = the
///   node-wide lurker pool is exhausted → `nodeSubscriptionLimit`
///   (retryable 4900 at the bridge, NOT `too_many_subscriptions`).
/// - **Any later close** → silent exponential-backoff reconnect
///   (1 s → 30 s, ×2), messages missed while down are dropped —
///   delivery is best-effort per the SWIP.
/// - **Dedup**: SHA-256 ring over the last 128 payloads, dropping
///   at-least-once duplicates before fan-out.
///
/// `SwarmSubscriptionConnecting` abstracts the actual WS dial so the
/// registry can be unit-tested (and the e2e harness can run an
/// in-memory pipeline) without a live gateway.
@MainActor
protocol SwarmSubscriptionHandle: AnyObject {
    /// Resolves when the pipeline is established; throws
    /// `SwarmSubscriptionError` otherwise. Called exactly once.
    func establish() async throws
    /// Fan-out sink for decoded payload bytes. Set before `establish`.
    var onMessage: (@MainActor (Data) -> Void)? { get set }
    func cancel()
}

enum SwarmSubscriptionError: Swift.Error, Equatable {
    /// Node-wide lurker pool exhausted (WS close 1013).
    case nodeSubscriptionLimit
    /// Gateway not reachable / refused — surfaces as 4900 node-stopped.
    case unreachable
}

/// Production WS pipeline against the in-process gateway.
@MainActor
final class SwarmSubscriptionSocket: SwarmSubscriptionHandle {
    /// ws:// base for the embedded gateway — same host/port as
    /// `BeeAPIClient.baseURL`.
    static let wsBase = URL(string: "ws://127.0.0.1:1633")!

    private static let establishGrace: Duration = .milliseconds(500)
    private static let reconnectBaseDelay: Duration = .seconds(1)
    private static let reconnectMaxDelay: Duration = .seconds(30)
    private static let dedupRingSize = 128

    var onMessage: (@MainActor (Data) -> Void)?

    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var runLoop: Task<Void, Never>?
    private var cancelled = false

    /// Payload-hash ring for at-least-once dedup (desktop parity).
    private var seenHashes = Set<Data>()
    private var seenOrder: [Data] = []

    /// `kind` "gsoc" → `/gsoc/subscribe/{key}`; "pss" → `/pss/subscribe/{key}`
    /// where key is the 64-hex address / hashed topic.
    init(kind: String, key: String, session: URLSession = .shared) {
        self.url = Self.wsBase.appendingPathComponent(
            "/\(kind)/subscribe/\(key)"
        )
        self.session = session
    }

    func establish() async throws {
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        // Race the receive pump against the grace timer: a quick
        // failure (refused connection, close 1013) loses to nothing
        // and surfaces its error; surviving the grace period wins.
        let pump = startReceivePump(on: task)
        do {
            try await Task.sleep(for: Self.establishGrace)
        } catch {
            pump.cancel()
            throw SwarmSubscriptionError.unreachable
        }
        if let failure = pumpFailure {
            pump.cancel()
            throw failure
        }
        // Surviving the grace period = established (the node refuses
        // fast and sends nothing on success) — from here the pump
        // reconnects on any later close.
        established = true
        runLoop = pump
    }

    private var pumpFailure: SwarmSubscriptionError?
    private var established = false

    /// Long-lived receive loop: pumps frames, and after establishment
    /// silently reconnects with backoff on close.
    private func startReceivePump(on initial: URLSessionWebSocketTask) -> Task<Void, Never> {
        Task { [weak self] in
            var current = initial
            var delay = Self.reconnectBaseDelay
            while !(self?.cancelled ?? true) {
                do {
                    let message = try await current.receive()
                    delay = Self.reconnectBaseDelay
                    guard let self, !self.cancelled else { return }
                    switch message {
                    case .data(let data):
                        self.deliver(data)
                    case .string(let string):
                        self.deliver(Data(string.utf8))
                    @unknown default:
                        break
                    }
                } catch {
                    guard let self, !self.cancelled else { return }
                    if !self.established {
                        // Pre-establishment failure: classify for the
                        // grace-window check in `establish()`. 1013
                        // ("try again later") isn't a named CloseCode
                        // case — NSURLSessionWebSocketCloseCode is a
                        // non-exhaustive @objc enum, so compare raw.
                        self.pumpFailure = current.closeCode.rawValue == 1013
                            ? .nodeSubscriptionLimit
                            : .unreachable
                        return
                    }
                    // Established pipeline dropped — reconnect with
                    // backoff. Messages in the gap are lost (SWIP:
                    // best-effort; apps catch up via the feed layer).
                    try? await Task.sleep(for: delay)
                    delay = min(delay * 2, Self.reconnectMaxDelay)
                    guard !self.cancelled else { return }
                    let next = self.session.webSocketTask(with: self.url)
                    self.task = next
                    next.resume()
                    current = next
                }
            }
        }
    }

    private func deliver(_ payload: Data) {
        let hash = Data(SHA256.hash(data: payload))
        guard !seenHashes.contains(hash) else { return }
        seenHashes.insert(hash)
        seenOrder.append(hash)
        if seenOrder.count > Self.dedupRingSize {
            seenHashes.remove(seenOrder.removeFirst())
        }
        onMessage?(payload)
    }

    func cancel() {
        cancelled = true
        runLoop?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}
