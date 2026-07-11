import Foundation

/// Per-origin rate + bandwidth budgets for the permission-free read
/// methods (`swarm_readFeedEntry`, `swarm_readChunk`,
/// `swarm_readSingleOwnerChunk`, `swarm_listFeeds`). SWIP
/// §"Permission-Free Reads" makes these limits a MUST — without them
/// any page could turn the user's node into a free retrieval proxy.
///
/// Fixed 60-second windows with desktop-matching numbers: connected
/// origins 600 requests / 5 MB, never-connected origins 120 requests
/// / 512 KB. In-memory only — resetting on relaunch is fine, the
/// budget protects bandwidth, it is not a security boundary. One
/// instance per app session (in `SwarmServices`), shared across tabs
/// so same-origin multi-tab reads draw from one budget.
@MainActor
final class SwarmReadBudget {
    struct Limits {
        let maxRequests: Int
        let maxBytes: Int

        static let connected = Limits(maxRequests: 600, maxBytes: 5 * 1024 * 1024)
        static let anonymous = Limits(maxRequests: 120, maxBytes: 512 * 1024)
    }

    static let window: TimeInterval = 60

    private struct Window {
        var start: Date
        var requests = 0
        var bytes = 0
    }

    private var windows: [String: Window] = [:]
    private let now: () -> Date

    /// Injectable clock so tests can roll the window without sleeping.
    init(now: @escaping () -> Date = { .now }) {
        self.now = now
    }

    /// Admission check + request-count increment. `false` → the caller
    /// replies `-32602` with `data.reason = "rate_limited"`. The byte
    /// budget is enforced retroactively: `recordBytes` from earlier
    /// reads can push the window over, blocking subsequent reads until
    /// the window rolls.
    func admit(origin: String, isConnected: Bool) -> Bool {
        let limits: Limits = isConnected ? .connected : .anonymous
        var window = currentWindow(origin: origin)
        guard window.requests < limits.maxRequests,
              window.bytes < limits.maxBytes else {
            windows[origin] = window
            return false
        }
        window.requests += 1
        windows[origin] = window
        return true
    }

    /// Called after a successful read with the payload size delivered
    /// to the page.
    func recordBytes(origin: String, bytes: Int) {
        var window = currentWindow(origin: origin)
        window.bytes += bytes
        windows[origin] = window
    }

    private func currentWindow(origin: String) -> Window {
        let current = now()
        if let window = windows[origin],
           current.timeIntervalSince(window.start) < Self.window {
            return window
        }
        return Window(start: current)
    }
}
