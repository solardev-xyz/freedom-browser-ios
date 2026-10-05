import BigInt
import Foundation

/// What a range-capped log scan is asking for: an `eth_getLogs` over a
/// numeric block range, with the caller's error classifiers (desktop
/// `logRange`). Only the Swarm node's scans through `AntChainBridge` are
/// range-capped; every other read leaves `Options.rangeCapOf` unset.
nonisolated struct LogScanRange: @unchecked Sendable {
    let fromBlock: Int
    let toBlock: Int
    let capOf: @Sendable (Swift.Error) -> Int?
    let rank: @Sendable (Swift.Error) -> ChainDataRouter.ErrorRank

    /// Both ends inclusive.
    var span: Int { toBlock - fromBlock + 1 }

    /// Nil when the request is not an `eth_getLogs` over two numeric
    /// block numbers (a tag such as `latest`, or a missing end, is never
    /// filtered or learned from). Desktop `logQuerySpan`.
    init?(
        method: String, params: [Any],
        capOf: @escaping @Sendable (Swift.Error) -> Int?,
        rank: @escaping @Sendable (Swift.Error) -> ChainDataRouter.ErrorRank
    ) {
        guard method == "eth_getLogs", let filter = params.first as? [String: Any],
              let from = Self.blockNumber(filter["fromBlock"]),
              let to = Self.blockNumber(filter["toBlock"]), to >= from else { return nil }
        fromBlock = from
        toBlock = to
        self.capOf = capOf
        self.rank = rank
    }

    static func blockNumber(_ value: Any?) -> Int? {
        guard let s = value as? String, s.count > 2, s.count <= 15, s.lowercased().hasPrefix("0x") else { return nil }
        return Int(s.dropFirst(2), radix: 16)
    }

    static func hex(_ block: Int) -> String { "0x" + String(block, radix: 16) }
}

/// What each RPC endpoint can serve for a range-capped log scan,
/// learned from its refusals (desktop `logRangeState`). Process-local
/// like `AdaptiveRouting`: nothing is saved, and a cap is relearned with
/// one refusal.
@MainActor
final class LogRangeMemory {
    struct Entry {
        /// The smallest span the endpoint refused; nil while none was.
        var refusedFrom: Int?
        var capUntil: Date = .distantPast
        /// An endpoint that failed for its own reasons sits out until then.
        var coolUntil: Date = .distantPast
    }

    /// How long a learned cap holds. After that the endpoint is asked for
    /// wider spans again, so a provider that raises its limit is noticed.
    static let capTTL: TimeInterval = 30 * 60
    /// How long a scan leaves out an endpoint that hung, refused the
    /// connection, throttled or failed some other way that does not
    /// depend on the requested range.
    static let cooldown: TimeInterval = 30
    /// Quorum rounds per scan: the first, and one with the endpoints left
    /// after the first round's failures were taken out.
    static let quorumRounds = 2

    private var entries: [String: Entry] = [:]
    private let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    private static func key(_ chainID: Int, _ url: URL) -> String { "\(chainID) \(url.absoluteString)" }

    /// The widest span `url` is expected to serve now: 0 while it cools
    /// down, `Int.max` while no cap is known.
    func servableSpan(chainID: Int, url: URL) -> Int {
        guard let entry = entries[Self.key(chainID, url)] else { return .max }
        let now = clock()
        if entry.coolUntil > now { return 0 }
        guard let refused = entry.refusedFrom, entry.capUntil > now else { return .max }
        return refused - 1
    }

    /// The widest span `m` of `urls` can serve together: what a quorum
    /// can still verify. 0 when fewer than `m` can serve any span.
    func quorumSpan(chainID: Int, urls: [URL], m: Int) -> Int {
        let spans = urls.map { servableSpan(chainID: chainID, url: $0) }.sorted(by: >)
        return spans.count >= m && m > 0 ? spans[m - 1] : 0
    }

    /// An answer ends a cooldown, and an answer at or above an expired
    /// cap clears it: the provider raised its limit.
    func noteAnswer(chainID: Int, url: URL, span: Int) {
        let key = Self.key(chainID, url)
        guard var entry = entries[key] else { return }
        if entry.refusedFrom == nil || span >= entry.refusedFrom! {
            entries.removeValue(forKey: key)
            return
        }
        entry.coolUntil = .distantPast
        entries[key] = entry
    }

    /// Learn from one endpoint's failed log query. A cap the reply names,
    /// or a range limit or upstream query timeout without one, bounds the
    /// span it is asked for. A failure that does not depend on the range
    /// (a hang, refused connection, throttle, lagging node) cools it down
    /// instead. Anything else (a reply that may be a throttle or a
    /// result-count cap) is not learned from. Desktop `noteLogRangeFailure`.
    func noteFailure(chainID: Int, url: URL, range: LogScanRange, error: Swift.Error) {
        let key = Self.key(chainID, url)
        var entry = entries[key] ?? Entry()
        let now = clock()
        let rank = range.rank(error)
        let clientTimeout = ChainDataRouter.failureKind(error) == .timeout
        var refusedFrom: Int?
        if let cap = range.capOf(error), cap > 0, cap < .max {
            refusedFrom = cap + 1
        } else if !clientTimeout, rank >= .timeout {
            refusedFrom = range.span
        }
        if let refusedFrom {
            if let current = entry.refusedFrom, entry.capUntil > now {
                entry.refusedFrom = min(current, refusedFrom)
            } else {
                entry.refusedFrom = refusedFrom
            }
            entry.capUntil = now.addingTimeInterval(Self.capTTL)
        } else if clientTimeout || rank <= .endpoint {
            entry.coolUntil = now.addingTimeInterval(Self.cooldown)
        } else {
            return
        }
        entries[key] = entry
    }

    func entry(chainID: Int, url: URL) -> Entry? { entries[Self.key(chainID, url)] }
}

/// What a range-capped scan gets when no quorum can serve its span: a
/// range limit naming the widest span one can, so Ant narrows its window
/// to it. Ranked `.request` by the bridge, so it ends the walk.
enum LogRangeRefusal {
    static let code = -32005

    static func error(span: Int) -> WalletRPC.Error {
        .rpc(code: code, message: "query exceeds max block range \(span)", data: nil)
    }
}

/// The second, independent source for the Swarm node's wallet scan
/// (freedom-browser #484): Blockscout's index of the wallet's xBZZ
/// transfers. No keyless Gnosis RPC outside Tenderly serves the full
/// history in one request, so a span no RPC quorum can serve is verified
/// by one capable endpoint's `eth_getLogs` agreeing exactly with this
/// index. Blockscout sees the node wallet's address with the device's IP.
@MainActor
final class BlockscoutTransferIndex {
    /// GET, redirects followed. Tests inject a stub.
    typealias Fetch = @Sendable (URL, TimeInterval) async throws -> Data

    nonisolated static let defaultBaseURL = URL(string: "https://gnosisscan.io/api/v2")!
    /// The display name in logs and trust evidence.
    static let label = "gnosisscan.io"
    static let chainID = 100
    /// xBZZ on Gnosis, lowercased.
    static let token = "0xdbf3ea6f5bee45c02255b2c26a16f300502f68da"
    static let transferTopic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
    /// Blocks below Blockscout's newest that are still left to the
    /// quorum, matching Ant's own reorg tail.
    static let reorgMargin = 64
    static let maxPages = 100
    static let pageTimeout: TimeInterval = 15
    static let totalBudget: TimeInterval = 60

    nonisolated static let defaultFetch: Fetch = { url, timeout in
        try await RPCSession.getBytes(url: url, timeout: timeout)
    }

    let baseURL: URL
    private let fetch: Fetch
    /// The user's switch (Settings → Chains → Gnosis → Indexer).
    var isEnabled: () -> Bool = { true }

    init(baseURL: URL = BlockscoutTransferIndex.defaultBaseURL, fetch: @escaping Fetch = BlockscoutTransferIndex.defaultFetch) {
        self.baseURL = baseURL
        self.fetch = fetch
    }

    struct Failure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// The one request shape this index can vouch for: Gnosis, `address`
    /// the xBZZ token as a single string, `topics` exactly
    /// `[Transfer, from]` with `from` a left-padded address, numeric
    /// ends, no `blockHash`. Returns the `from` address, lowercased.
    static func eligibleSender(chainID: Int, params: [Any]) -> String? {
        guard chainID == Self.chainID, params.count == 1,
              let filter = params.first as? [String: Any], filter["blockHash"] == nil,
              (filter["address"] as? String)?.lowercased() == token,
              let topics = filter["topics"] as? [Any], topics.count == 2,
              (topics[0] as? String)?.lowercased() == transferTopic,
              let fromTopic = (topics[1] as? String)?.lowercased(),
              let sender = address(fromTopic: fromTopic) else { return nil }
        return sender
    }

    /// `0x` + 24 zero hex digits + 40 address hex digits → `0x<address>`.
    static func address(fromTopic topic: String) -> String? {
        guard topic.count == 66, topic.hasPrefix("0x"),
              topic.dropFirst(2).allSatisfy(\.isHexDigit),
              topic.dropFirst(2).prefix(24).allSatisfy({ $0 == "0" }) else { return nil }
        return "0x" + topic.suffix(40)
    }

    /// Blockscout's newest indexed block, only while it reports its block
    /// history complete: it indexes new blocks live and back-fills old ones
    /// separately, so during a back-fill the head is current but old
    /// transfers can be missing.
    func indexedHeight() async throws -> Int {
        let fetch = self.fetch
        let statusURL = baseURL.appendingPathComponent("main-page/indexing-status")
        let blocksURL = baseURL.appendingPathComponent("main-page/blocks")
        async let statusData = fetch(statusURL, Self.pageTimeout)
        async let blocksData = fetch(blocksURL, Self.pageTimeout)
        let (status, blocks) = try await (statusData, blocksData)
        guard let state = try? JSONSerialization.jsonObject(with: status) as? [String: Any],
              (state["finished_indexing_blocks"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue }) == true else {
            throw Failure(reason: "Blockscout is still indexing old blocks")
        }
        guard let list = try? JSONSerialization.jsonObject(with: blocks) as? [[String: Any]],
              let height = Self.integer(list.first?["height"]) else {
            throw Failure(reason: "Blockscout returned no indexed height")
        }
        return height
    }

    /// One transfer as both sides describe it: block, transaction, log
    /// index, recipient, amount.
    struct TransferKey: Hashable, Comparable, CustomStringConvertible {
        let block: Int
        let transaction: String
        let logIndex: Int
        let to: String
        let value: String

        static func < (a: Self, b: Self) -> Bool { (a.block, a.logIndex) < (b.block, b.logIndex) }
        var description: String { "\(block)|\(transaction)|\(logIndex)|\(to)|\(value)" }
    }

    /// Every xBZZ transfer from `sender` in `[fromBlock, toBlock]`,
    /// paged through `next_page_params`. Throws past `maxPages`, on any
    /// failed page, or past the total budget: an index read that cannot
    /// be completed verifies nothing.
    func transfers(from sender: String, fromBlock: Int, toBlock: Int) async throws -> [TransferKey] {
        let started = ContinuousClock.now
        var keys: [TransferKey] = []
        var next: [String: Any]? = [:]
        var pages = 0
        while let params = next {
            pages += 1
            guard pages <= Self.maxPages else {
                throw Failure(reason: "Blockscout lists more than \(Self.maxPages) pages")
            }
            let elapsed = started.duration(to: .now)
            let left = Self.totalBudget - (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            guard left > 0 else { throw Failure(reason: "Blockscout read took over \(Int(Self.totalBudget))s") }
            let data = try await fetch(pageURL(sender: sender, next: params), min(Self.pageTimeout, left))
            guard let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = page["items"] as? [[String: Any]] else {
                throw Failure(reason: "Blockscout page is not a transfer list")
            }
            for item in items {
                guard ((item["from"] as? [String: Any])?["hash"] as? String)?.lowercased() == sender else {
                    throw Failure(reason: "Blockscout listed a transfer from another address")
                }
                guard (((item["token"] as? [String: Any])?["address_hash"]
                        ?? (item["token"] as? [String: Any])?["address"]) as? String)?.lowercased() == Self.token,
                      let block = Self.integer(item["block_number"]),
                      block >= fromBlock, block <= toBlock else { continue }
                guard let tx = (item["transaction_hash"] as? String)?.lowercased(),
                      let logIndex = Self.integer(item["log_index"]),
                      let to = ((item["to"] as? [String: Any])?["hash"] as? String)?.lowercased(),
                      let value = (item["total"] as? [String: Any])?["value"] as? String,
                      let amount = BigUInt(value) else {
                    throw Failure(reason: "Blockscout transfer is missing a field")
                }
                keys.append(TransferKey(block: block, transaction: tx, logIndex: logIndex, to: to, value: String(amount)))
            }
            next = page["next_page_params"] as? [String: Any]
        }
        return keys
    }

    private func pageURL(sender: String, next: [String: Any]) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("addresses/\(sender)/token-transfers"),
            resolvingAgainstBaseURL: false
        )!
        var query = ["type": "ERC-20", "filter": "from", "token": Self.token]
        for (key, value) in next {
            query[key] = value is NSNull ? "" : "\(value)"
        }
        components.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        return components.url!
    }

    /// The same key read off an RPC log; nil unless the log is an xBZZ
    /// `Transfer` with three topics, sent by `sender`.
    static func key(rpcLog value: Any, sender: String) -> TransferKey? {
        guard let log = value as? [String: Any],
              (log["address"] as? String)?.lowercased() == token,
              let topics = log["topics"] as? [String], topics.count == 3,
              topics[0].lowercased() == transferTopic,
              address(fromTopic: topics[1].lowercased()) == sender,
              let to = address(fromTopic: topics[2].lowercased()),
              let block = LogScanRange.blockNumber(log["blockNumber"]),
              let tx = (log["transactionHash"] as? String)?.lowercased(),
              let logIndex = LogScanRange.blockNumber(log["logIndex"]),
              let data = log["data"] as? String, data.lowercased().hasPrefix("0x"),
              let amount = data.count == 2 ? BigUInt(0) : BigUInt(data.dropFirst(2), radix: 16) else { return nil }
        return TransferKey(block: block, transaction: tx, logIndex: logIndex, to: to, value: String(amount))
    }

    private static func integer(_ value: Any?) -> Int? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }
}
