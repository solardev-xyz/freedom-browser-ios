import Foundation

@MainActor
final class AnchorCorroboration {
    typealias HeadFetcher = @Sendable (URL, BlockAnchor, TimeInterval) async throws -> UInt64
    typealias HashFetcher = @Sendable (URL, UInt64, TimeInterval) async throws -> String

    struct PinnedBlock: Equatable {
        let anchor: BlockAnchor
        let number: UInt64
        let hash: String
    }

    enum AnchorError: Error, Equatable {
        case hashDisagreement(largestBucketSize: Int, total: Int, threshold: Int)
    }

    // Median needs ≥3 samples to tolerate 1 outlier on either side. A
    // configured K<3 or a runtime <3 responders falls through to the
    // single-source unverified path instead of minting a "verified" badge
    // we can't defend.
    static let minQuorumProviders = 3

    private let pool: EthereumRPCPool
    private let settings: SettingsStore
    private let clock: () -> Date
    private let fetchHead: HeadFetcher
    private let fetchHash: HashFetcher

    private var cachedEntry: CachedEntry?

    private struct CachedEntry {
        let block: PinnedBlock
        let expiresAt: Date
    }

    init(
        pool: EthereumRPCPool,
        settings: SettingsStore,
        clock: @escaping () -> Date = Date.init,
        fetchHead: @escaping HeadFetcher = EthereumHeadFetcher.head,
        fetchHash: @escaping HashFetcher = EthereumHeadFetcher.hash
    ) {
        self.pool = pool
        self.settings = settings
        self.clock = clock
        self.fetchHead = fetchHead
        self.fetchHash = fetchHash
    }

    /// Pinned block for the current quorum wave. Returns nil when
    /// corroboration isn't feasible (fewer than 3 providers available, or
    /// too many head-fetch failures) — the caller then degrades to
    /// single-source unverified. Throws on genuine hash disagreement,
    /// which is a security signal retrying won't fix.
    func getPinnedBlock() async throws -> PinnedBlock? {
        let anchor = settings.ensBlockAnchor
        let ttl = TimeInterval(settings.ensBlockAnchorTtlMs) / 1000
        let timeout = TimeInterval(settings.ensQuorumTimeoutMs) / 1000
        let desiredM = max(2, min(settings.ensQuorumM, settings.ensQuorumK))

        if let cached = cachedEntry,
           cached.block.anchor == anchor,
           clock() < cached.expiresAt {
            return cached.block
        }

        let available = pool.availableProviders()
        guard available.count >= Self.minQuorumProviders else { return nil }

        let heads = await probeHeads(providers: available, anchor: anchor, timeout: timeout)
        guard heads.count >= Self.minQuorumProviders else { return nil }

        // Median tolerates up to (K-1)/2 liars on either side. Min is
        // unsafe (attacker-lowest wins), max DoSes on not-yet-available,
        // average is manipulable by extreme values.
        let sortedHeads = heads.map(\.number).sorted()
        let medianHead = sortedHeads[sortedHeads.count / 2]
        let depth = anchor.safetyDepth
        let targetNumber = medianHead > depth ? medianHead - depth : 0
        let effectiveM = min(desiredM, available.count)

        let agreedHash = try await agreeOnHash(
            at: targetNumber, across: heads, timeout: timeout, effectiveM: effectiveM
        )

        let block = PinnedBlock(anchor: anchor, number: targetNumber, hash: agreedHash)
        cachedEntry = CachedEntry(block: block, expiresAt: clock().addingTimeInterval(ttl))
        return block
    }

    func invalidate() {
        cachedEntry = nil
    }

    /// Head → depth → hash chain against one provider. Same three-step
    /// pipeline as the quorum path but without cross-provider
    /// corroboration. Used for the degraded unverified fallback.
    func singleSourceAnchor(url: URL) async throws -> PinnedBlock {
        let anchor = settings.ensBlockAnchor
        let timeout = TimeInterval(settings.ensQuorumTimeoutMs) / 1000
        let head = try await fetchHead(url, anchor, timeout)
        let depth = anchor.safetyDepth
        let targetNumber = head > depth ? head - depth : 0
        let hash = try await fetchHash(url, targetNumber, timeout)
        return PinnedBlock(anchor: anchor, number: targetNumber, hash: hash)
    }

    // MARK: - Phases

    private func probeHeads(
        providers: [URL],
        anchor: BlockAnchor,
        timeout: TimeInterval
    ) async -> [(url: URL, number: UInt64)] {
        // Probing the whole pool (vs first K) keeps the median robust when a
        // few providers flake — one liar or one outlier gets outvoted by the
        // honest remainder.
        let results = await withTaskGroup(of: HeadResult.self) { group in
            for url in providers {
                group.addTask { [fetchHead] in
                    do {
                        let n = try await fetchHead(url, anchor, timeout)
                        return .success(url: url, number: n)
                    } catch {
                        return .failure(url: url)
                    }
                }
            }
            return await group.reduce(into: [HeadResult]()) { $0.append($1) }
        }

        var heads: [(url: URL, number: UInt64)] = []
        for r in results {
            switch r {
            case .success(let url, let n):
                heads.append((url, n))
                pool.markSuccess(url)
            case .failure(let url):
                pool.markFailure(url)
            }
        }
        return heads
    }

    /// Asks every head-responder for the hash at `blockNumber`, then
    /// requires the plurality winner to also clear strict majority of
    /// actual respondents. Plurality alone would let two colluding
    /// providers satisfy user-M=2 against a larger honest bucket that
    /// merely disagreed internally — attacker-majority was out of scope
    /// but attacker-plurality isn't.
    private func agreeOnHash(
        at blockNumber: UInt64,
        across heads: [(url: URL, number: UInt64)],
        timeout: TimeInterval,
        effectiveM: Int
    ) async throws -> String {
        let results = await withTaskGroup(of: HashResult.self) { group in
            for (url, _) in heads {
                group.addTask { [fetchHash] in
                    do {
                        let h = try await fetchHash(url, blockNumber, timeout)
                        return .success(url: url, hash: h)
                    } catch {
                        return .failure(url: url)
                    }
                }
            }
            return await group.reduce(into: [HashResult]()) { $0.append($1) }
        }

        var byHash: [String: [URL]] = [:]
        for r in results {
            switch r {
            case .success(let url, let hash):
                byHash[hash, default: []].append(url)
            case .failure(let url):
                pool.markFailure(url)
            }
        }

        let total = byHash.values.reduce(0) { $0 + $1.count }
        let winner = byHash.max(by: { $0.value.count < $1.value.count }) ?? (key: "", value: [])
        let majorityThreshold = total / 2 + 1
        let hashQuorumThreshold = max(effectiveM, majorityThreshold)

        guard winner.value.count >= hashQuorumThreshold else {
            throw AnchorError.hashDisagreement(
                largestBucketSize: winner.value.count,
                total: total,
                threshold: hashQuorumThreshold
            )
        }
        for url in winner.value { pool.markSuccess(url) }
        return winner.key
    }

    private enum HeadResult {
        case success(url: URL, number: UInt64)
        case failure(url: URL)
    }

    private enum HashResult {
        case success(url: URL, hash: String)
        case failure(url: URL)
    }
}

private extension BlockAnchor {
    var safetyDepth: UInt64 {
        switch self {
        case .latest: 8
        case .latestMinus32: 32
        case .finalized: 0
        }
    }
}

// MARK: - Default RPC implementation

enum EthereumHeadFetcher {
    static func head(url: URL, anchor: BlockAnchor, timeout: TimeInterval) async throws -> UInt64 {
        switch anchor {
        case .latest, .latestMinus32:
            return try await blockNumber(url: url, timeout: timeout)
        case .finalized:
            return try await getBlock(url: url, tag: "finalized", timeout: timeout).number
        }
    }

    static func hash(url: URL, number: UInt64, timeout: TimeInterval) async throws -> String {
        let tag = "0x" + String(number, radix: 16)
        return try await getBlock(url: url, tag: tag, timeout: timeout).hash
    }

    private struct BlockData: Decodable {
        let number: UInt64
        let hash: String

        enum CodingKeys: String, CodingKey { case number, hash }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let numberHex = try c.decode(String.self, forKey: .number)
            guard let n = parseHex(numberHex) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .number, in: c, debugDescription: "expected hex block number"
                )
            }
            self.number = n
            self.hash = try c.decode(String.self, forKey: .hash)
        }
    }

    private static func blockNumber(url: URL, timeout: TimeInterval) async throws -> UInt64 {
        struct Body: Encodable {
            let jsonrpc = "2.0"
            let id = 1
            let method = "eth_blockNumber"
            let params: [String] = []
        }
        let resp: RPCSession.Response<String> = try await RPCSession.post(
            url: url, body: Body(), timeout: timeout
        )
        if let err = resp.error {
            throw RPCError.jsonRpc(code: err.code, message: err.message)
        }
        guard let hex = resp.result, let n = parseHex(hex) else {
            throw RPCError.emptyResponse
        }
        return n
    }

    private static func getBlock(url: URL, tag: String, timeout: TimeInterval) async throws -> BlockData {
        struct Body: Encodable {
            let jsonrpc = "2.0"
            let id = 1
            let method = "eth_getBlockByNumber"
            let params: [Param]

            enum Param: Encodable {
                case string(String)
                case bool(Bool)
                func encode(to encoder: Encoder) throws {
                    var c = encoder.singleValueContainer()
                    switch self {
                    case .string(let s): try c.encode(s)
                    case .bool(let b): try c.encode(b)
                    }
                }
            }
        }
        let body = Body(params: [.string(tag), .bool(false)])
        let resp: RPCSession.Response<BlockData> = try await RPCSession.post(
            url: url, body: body, timeout: timeout
        )
        if let err = resp.error {
            throw RPCError.jsonRpc(code: err.code, message: err.message)
        }
        guard let block = resp.result else {
            throw RPCError.emptyResponse
        }
        return block
    }

    private static func parseHex(_ s: String) -> UInt64? {
        let stripped = s.hasPrefix("0x") ? String(s.dropFirst(2)) : s
        return UInt64(stripped, radix: 16)
    }
}
