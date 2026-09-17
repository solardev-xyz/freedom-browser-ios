import Colibri
import Foundation
import MyotisKit
import OSLog

private nonisolated let log = Logger(subsystem: "com.browser.Freedom", category: "MyotisCheckpoint")

/// The app-side half of Myotis stale-anchor recovery: corroborates a
/// quorum-endorsed checkpoint with a Colibri committee-history proof.
/// Port of desktop `checkpoint-verifier-worker.js` `verifyCheckpoint`
/// (PR #353) onto the Colibri Swift binding.
///
/// Mechanism: `MyotisCheckpointAcquirer` fetches a zk proof for the
/// latest block from the network's Colibri prover and hands it here.
/// A *disposable* Colibri verifier (fresh in-memory storage, so no
/// cached committee can short-circuit the bootstrap) verifies it. To
/// verify, Colibri must fetch the beacon block root its committee
/// checkpoint is Merkle-proven against — that request is intercepted
/// (`requestHandler`) and answered with the root the external quorum
/// endorsed for that exact slot. Colibri therefore only ever sees the
/// quorum's root; a successful verification binds the proof's committee
/// history to it. Anything else Colibri tries to fetch is refused.
///
/// What this does NOT prove (desktop `myotis-colibri-corroboration`
/// audit): the proof alone cannot distinguish canonical history from a
/// historical-key forgery, so Colibri corroborates the quorum, it does
/// not replace it. Myotis then verifies forward from the root with its
/// own BLS / snapshot-probation / weak-subjectivity checks.
nonisolated final class ColibriCheckpointCorroborator: MyotisCheckpointCorroborator, @unchecked Sendable {
    /// Colibri's storage is a process global; corroborations run one
    /// at a time so mainnet and Gnosis recoveries never share a
    /// verifier state.
    private static let gate = Gate()

    func corroborate(
        network: MyotisCheckpointNetwork,
        proof: Data,
        trust: @escaping @concurrent @Sendable (UInt64) async throws -> MyotisCheckpointObservation
    ) async throws -> [MyotisCheckpointObservation] {
        try await Self.gate.run {
            try await ColibriDiskStorage.withEphemeralStorage {
                try await Self.verify(network: network, proof: proof, trust: trust)
            }
        }
    }

    private static func verify(
        network: MyotisCheckpointNetwork,
        proof: Data,
        trust: @escaping @Sendable (UInt64) async throws -> MyotisCheckpointObservation
    ) async throws -> [MyotisCheckpointObservation] {
        let client = Colibri()
        client.chainId = network.chainId
        client.zkProof = true
        client.privacyMode = .basic
        client.maxLatestAgeSeconds = 60
        // The interception origin. `requestHandler` answers EVERY request
        // the verifier makes, so no server in these lists is contacted;
        // they only shape the URL the handler is asked to serve.
        client.checkpointz = [network.source]
        client.provers = [network.prover]
        let interceptor = Interceptor(source: network.source, trust: trust)
        client.requestHandler = interceptor
        do {
            _ = try await client.verifyProof(
                proof: proof, method: "eth_getBlockByNumber", params: "[\"latest\",false]"
            )
        } catch {
            if let transport = interceptor.transportError { throw transport }
            let text = String(describing: error)
            if text.range(of: "proof for latest too old", options: .caseInsensitive) != nil {
                throw MyotisCheckpointError.stale
            }
            log.notice("[checkpoint] colibri verification failed chain=\(network.chainId) error=\(text, privacy: .public)")
            throw MyotisCheckpointError.mismatch
        }
        if let transport = interceptor.transportError { throw transport }
        return interceptor.observations
    }

    /// Request policy (desktop `fetch` interceptor): only
    /// `GET {source}/eth/v1/beacon/blocks/{slot}/root`, no query, no
    /// fragment, at most `maxRequests` — answered from the quorum.
    static func acceptedSlot(url: String, method: String, source: String) -> UInt64? {
        guard method.uppercased() == "GET" else { return nil }
        guard url.hasPrefix(source + "/") else { return nil }
        var path = Substring(url.dropFirst(source.count))
        // The binding joins "<server>/<uri>"; a uri that already starts
        // with "/" yields "//eth/…". Collapse that one join seam only.
        while path.hasPrefix("//") { path = path.dropFirst() }
        guard !path.contains("?"), !path.contains("#"), !path.contains("@") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // ["", "eth", "v1", "beacon", "blocks", "<slot>", "root"]
        guard parts.count == 7, parts[0].isEmpty, parts[1] == "eth", parts[2] == "v1",
              parts[3] == "beacon", parts[4] == "blocks", parts[6] == "root",
              !parts[5].isEmpty, parts[5].allSatisfy(\.isNumber),
              let slot = UInt64(parts[5])
        else { return nil }
        return slot
    }

    nonisolated final class Interceptor: RequestHandler, @unchecked Sendable {
        static let maxRequests = MyotisCheckpointAcquirer.maxTrustRequests
        private let source: String
        private let trust: @Sendable (UInt64) async throws -> MyotisCheckpointObservation
        private let lock = NSLock()
        private var count = 0
        private(set) var observations: [MyotisCheckpointObservation] = []
        private(set) var transportError: MyotisCheckpointError?

        init(source: String, trust: @escaping @Sendable (UInt64) async throws -> MyotisCheckpointObservation) {
            self.source = source
            self.trust = trust
        }

        func handleRequest(_ request: DataRequest) async throws -> Data {
            do {
                guard let slot = ColibriCheckpointCorroborator.acceptedSlot(
                    url: request.url, method: request.method, source: source
                ) else {
                    log.notice("[checkpoint] refused verifier request \(request.method, privacy: .public) \(request.url, privacy: .public)")
                    throw MyotisCheckpointError.mismatch
                }
                let over: Bool = lock.withLock {
                    count += 1
                    return count > Self.maxRequests
                }
                if over { throw MyotisCheckpointError.unavailable }
                let observation = try await trust(slot)
                lock.withLock { observations.append(observation) }
                let body = try JSONSerialization.data(withJSONObject: ["data": ["root": observation.root]])
                return body
            } catch {
                // Colibri wraps handler failures in verifier errors; keep
                // the original class so an outage is never presented as
                // conflicting proof.
                let wrapped = MyotisCheckpointError.wrap(error)
                lock.withLock { if transportError == nil { transportError = wrapped } }
                throw wrapped
            }
        }
    }

    /// Serializes corroborations (an async mutex).
    private actor Gate {
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
            await acquire()
            defer { release() }
            return try await body()
        }

        private func acquire() async {
            if !busy { busy = true; return }
            await withCheckedContinuation { waiters.append($0) }
        }

        private func release() {
            if let next = waiters.first {
                waiters.removeFirst()
                next.resume()
            } else {
                busy = false
            }
        }
    }
}
