import Foundation
import OSLog

private let log = Logger(subsystem: "com.browser.Freedom", category: "ChainData")

/// What one quorum member said. A deterministic protocol answer (a
/// revert with data, `-32602`, insufficient funds) is an answer too:
/// M members agreeing on the same revert is a verified revert, which
/// desktop loses when every member reverts.
enum QuorumLegAnswer {
    case value(Any)
    case deterministic(WalletRPC.Error)

    /// Stable serialization so members are bucketed by bytes, not by
    /// object identity (desktop `stableValue`).
    var bucketKey: String {
        switch self {
        case .value(let v): return "v:" + StableJSON.string(v)
        case .deterministic(let e): return "e:" + (e.errorDescription ?? "")
        }
    }
}

/// The highest-priority successful quorum member, handed to the direct
/// tier when agreement became impossible so it does not repeat the
/// call (desktop `error.directFallback`).
struct DirectFallback {
    let url: URL
    let answer: QuorumLegAnswer
    let agreedURLs: [URL]
    let dissentedURLs: [URL]
    let queriedURLs: [URL]
    let k: Int
    let m: Int
}

enum QuorumOutcome {
    case agreed(QuorumLegAnswer, trust: ENSTrust)
    case failed(reason: String, kind: ChainSourceFailureKind?, fallback: DirectFallback?, attempted: [URL], errors: [Error])
}

/// One leg's result as the router's transport reports it.
enum QuorumLegResult {
    case answer(QuorumLegAnswer)
    case error(Error, kind: ChainSourceFailureKind?)
}

/// One M-of-K wave: K legs in flight, settled as soon as M agree,
/// failed as soon as agreement is impossible — unless a direct tier
/// follows, in which case a member still running may finish inside the
/// direct tier's budget and serve it. Unpinned, like desktop's generic
/// quorum: honest endpoints at different heads can disagree, which the
/// UI words as "try again".
@MainActor
final class QuorumRun {
    private struct Group {
        let answer: QuorumLegAnswer
        var urls: [URL]
    }

    private let urls: [URL]
    private let m: Int
    private let allowDirectFallback: Bool
    private var groups: [String: Group] = [:]
    private var fulfilled: [URL] = []
    private var candidates: [(index: Int, url: URL, answer: QuorumLegAnswer)] = []
    private var errors: [Error] = []
    private var errorKinds: [ChainSourceFailureKind] = []
    private var pending: Int
    private var finished = false
    private var verificationImpossible = false
    private let first = FirstSettled<QuorumOutcome>()
    private var legs: [Task<Void, Never>] = []
    private var timer: Task<Void, Never>?

    init(urls: [URL], m: Int, allowDirectFallback: Bool) {
        self.urls = urls
        self.m = m
        self.allowDirectFallback = allowDirectFallback
        self.pending = urls.count
    }

    /// `timeout` bounds verification; `leg` runs one member and must
    /// bound itself with the endpoint timeout.
    func run(
        timeout: TimeInterval,
        leg: @escaping @MainActor (URL) async -> QuorumLegResult
    ) async -> QuorumOutcome {
        for (index, url) in urls.enumerated() {
            legs.append(Task { @MainActor [weak self] in
                let result = await leg(url)
                self?.legFinished(index: index, url: url, result: result)
            })
        }
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0.001, timeout)))
            guard !Task.isCancelled else { return }
            self?.timerFired()
        }
        do {
            return try await first.wait()
        } catch {
            // Only cancellation reaches here; the wave itself never throws.
            finish()
            return .failed(reason: "cancelled", kind: nil, fallback: nil, attempted: urls, errors: errors)
        }
    }

    private func legFinished(index: Int, url: URL, result: QuorumLegResult) {
        guard !finished else { return }
        pending -= 1
        switch result {
        case .answer(let answer):
            fulfilled.append(url)
            candidates.append((index, url, answer))
            let key = answer.bucketKey
            var group = groups[key] ?? Group(answer: answer, urls: [])
            group.urls.append(url)
            groups[key] = group
            if group.urls.count >= m {
                succeed(group)
            } else if verificationImpossible {
                fail()
            } else {
                rejectIfImpossible()
            }
        case .error(let error, let kind):
            errors.append(error)
            if let kind { errorKinds.append(kind) }
            rejectIfImpossible()
        }
    }

    private func timerFired() {
        guard !finished else { return }
        verificationImpossible = true
        if !allowDirectFallback || !candidates.isEmpty || pending == 0 { fail() }
    }

    private func rejectIfImpossible() {
        guard !finished else { return }
        let largest = groups.values.map(\.urls.count).max() ?? 0
        if largest + pending >= m { return }
        verificationImpossible = true
        // If every completed member failed, let an already-running member
        // finish within the direct tier's budget: its answer cannot
        // restore quorum, but it can satisfy direct without a duplicate.
        if !allowDirectFallback || !candidates.isEmpty || pending == 0 { fail() }
    }

    private func finish() {
        finished = true
        timer?.cancel()
        legs.forEach { $0.cancel() }
    }

    private func succeed(_ group: Group) {
        finish()
        let agreed = Set(group.urls)
        let trust = ENSTrust(
            level: .verified,
            method: .quorum,
            block: ENSBlock(number: 0, hash: ""),
            agreed: group.urls.map(\.hostOrAbsolute),
            dissented: fulfilled.filter { !agreed.contains($0) }.map(\.hostOrAbsolute),
            queried: urls.map(\.hostOrAbsolute),
            k: urls.count,
            m: m
        )
        first.settle(.success(.agreed(group.answer, trust: trust)))
    }

    private func fail() {
        finish()
        let capacityFailures = errorKinds.filter { $0 == .capacity }.count
        let timedOut = errorKinds.contains(.timeout)
        let kind: ChainSourceFailureKind? = capacityFailures >= m ? .capacity : (timedOut ? .timeout : nil)
        var fallback: DirectFallback?
        if let best = candidates.min(by: { $0.index < $1.index }) {
            let key = best.answer.bucketKey
            fallback = DirectFallback(
                url: best.url,
                answer: best.answer,
                agreedURLs: candidates.filter { $0.answer.bucketKey == key }.map(\.url),
                dissentedURLs: candidates.filter { $0.answer.bucketKey != key }.map(\.url),
                queriedURLs: urls,
                k: urls.count,
                m: m
            )
        }
        first.settle(.success(.failed(
            reason: "RPC quorum did not reach \(m) matching responses",
            kind: kind, fallback: fallback, attempted: urls, errors: errors
        )))
    }
}

/// Deterministic serialization of a Foundation JSON value: object keys
/// sorted, no whitespace. Two endpoints agree when their `result`
/// serializes identically.
enum StableJSON {
    static func string(_ value: Any) -> String {
        switch value {
        case let dict as [String: Any]:
            let body = dict.keys.sorted().map { key in
                "\(quote(key)):\(string(dict[key]!))"
            }.joined(separator: ",")
            return "{\(body)}"
        case let list as [Any]:
            return "[" + list.map(string).joined(separator: ",") + "]"
        case is NSNull:
            return "null"
        case let s as String:
            return quote(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        default:
            return String(describing: value)
        }
    }

    private static func quote(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed]),
              let out = String(data: data, encoding: .utf8) else { return "\"\(s)\"" }
        return out
    }
}
