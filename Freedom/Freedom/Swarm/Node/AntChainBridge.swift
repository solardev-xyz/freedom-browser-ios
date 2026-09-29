import Foundation
import OSLog

private let log = Logger(subsystem: "com.browser.Freedom", category: "AntChain")

/// Serves the embedded Swarm node's Gnosis JSON-RPC requests from the
/// app's chain-data router — desktop's `ant-chain-bridge.js` (PR #419)
/// over ant's host transport callback (`ant_set_chain_transport`, ant
/// #77) instead of a loopback HTTP endpoint.
///
/// Ant keeps issuing exactly the eight requests it always issued; this
/// only decides where they are answered: reads follow Gnosis's
/// configured policy (Myotis → Colibri → RPC quorum → direct), signed
/// transactions the broadcast policy. A read that exhausts every source
/// comes back as a JSON-RPC error, never as a fabricated empty result
/// and never as a `-32000` (ant's "coverage gap, ask the pinned URL
/// instead" signal — for a broadcast that would be a second send).
///
/// The callback runs on ant's blocking pool; `serve` blocks that thread
/// on a main-actor task. `SwarmNode` never calls into ant from the
/// main actor while a start is in flight, so the two never wait on each
/// other.
@MainActor
final class AntChainBridge {
    static let chainID = 100
    static let readMethods: Set<String> = [
        "eth_call", "eth_getBalance", "eth_getLogs", "eth_getTransactionReceipt",
        "eth_getTransactionCount", "eth_blockNumber", "eth_getCode",
    ]
    static let broadcastMethod = "eth_sendRawTransaction"
    /// Desktop `MAX_RESPONSE`: a body ant would not accept anyway.
    static let maxResponseBytes = 16 * 1024 * 1024
    static let maxErrorMessage = 500
    /// A wide log scan gets a longer per-URL budget on the direct path
    /// than an interactive read (desktop `LOG_SCAN_DIRECT_TIMEOUT_MS`).
    static let logScanDirectTimeout: TimeInterval = 60
    /// Desktop `timeoutMs`: the whole routed request.
    static let requestTimeout: TimeInterval = 120

    private let router: ChainDataRouter

    init(router: ChainDataRouter) {
        self.router = router
    }

    /// The closure `SwarmNode.chainTransport` takes. Blocks the calling
    /// (non-main) thread until the router answers.
    nonisolated var transport: @Sendable (String) -> String? {
        { [self] request in
            let box = ResultBox()
            let done = DispatchSemaphore(value: 0)
            Task { @MainActor in
                box.value = await self.serve(request)
                done.signal()
            }
            done.wait()
            return box.value
        }
    }

    /// One JSON-RPC request in, one response body out (`nil` only when
    /// the request cannot even be parsed as JSON — ant then falls back
    /// to its pinned URL, which is also what it does for a body it can't
    /// read).
    func serve(_ raw: String) async -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return Self.encode(Self.errorBody(id: NSNull(), code: -32700, message: "Invalid JSON"))
        }
        guard let request = object as? [String: Any],
              request["jsonrpc"] as? String == "2.0",
              let id = request["id"], Self.validID(id),
              let params = request["params"] as? [Any] else {
            return Self.encode(Self.errorBody(id: NSNull(), code: -32600, message: "Single JSON-RPC request with id and params required"))
        }
        let method = request["method"] as? String ?? ""
        guard Self.readMethods.contains(method) || method == Self.broadcastMethod else {
            return Self.encode(Self.errorBody(id: id, code: -32601, message: "Method not available to Ant"))
        }

        do {
            let result: Any
            let source: ChainSource
            if method == Self.broadcastMethod {
                guard params.count == 1, let rawTransaction = params[0] as? String,
                      SignedTransactionInspector.chainID(rawTransaction: rawTransaction) == Self.chainID else {
                    return Self.encode(Self.errorBody(id: id, code: -32602, message: "Expected a signed Gnosis transaction"))
                }
                let receipt = try await withTimeout(Self.requestTimeout) {
                    try await self.router.broadcast(chainID: Self.chainID, rawTransaction: rawTransaction)
                }
                result = receipt.hash
                source = receipt.source
            } else {
                var options = ChainDataRouter.Options()
                // Ant's polling must not queue ahead of wallet/app reads.
                options.background = true
                if method == "eth_getLogs" {
                    options.directTimeout = Self.logScanDirectTimeout
                    options.rankError = { AntLogScanErrors.rank($0) }
                }
                let answer = try await withTimeout(Self.requestTimeout) {
                    try await self.router.request(chainID: Self.chainID, method: method, params: params, context: .wallet, options: options)
                }
                result = answer.result
                source = answer.source
            }
            let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
            guard let encoded = Self.encode(body) else {
                return Self.encode(Self.errorBody(id: id, code: -32002, message: "Chain response is not JSON"))
            }
            if encoded.utf8.count > Self.maxResponseBytes {
                return Self.encode(Self.errorBody(id: id, code: -32002, message: "Chain response exceeds bridge limit"))
            }
            log.info("[Ant chain] \(method, privacy: .public) via \(source.rawValue, privacy: .public)")
            return encoded
        } catch {
            let reply = Self.errorReply(method: method, error: error)
            log.warning("[Ant chain] \(method, privacy: .public) failed (\(reply.code))")
            return Self.encode(Self.errorBody(id: id, code: reply.code, message: reply.message, data: reply.data))
        }
    }

    // MARK: - Error mapping (desktop `antErrorReply`)

    struct ErrorReply: Equatable {
        let code: Int
        let message: String
        let data: String?
    }

    /// The JSON-RPC error ant receives for a failed routed request. Codes
    /// survive except `-32000`, which on the FFI transport means "can't
    /// serve, replay against the pinned URL" and is therefore never
    /// emitted for a genuine failure.
    static func errorReply(method: String, error: Swift.Error) -> ErrorReply {
        let leaf = Self.leaf(error)
        var code = -32002
        var data: String?
        var detail = Self.sanitize(ChainDataRouter.safeErrorMessage(leaf))
        var message: String?
        if let rpc = leaf as? WalletRPC.Error {
            switch rpc {
            case .rpc(let c, let m, let d):
                code = c
                detail = Self.sanitize(m)
                if let d, d.hasPrefix("0x"), d.count <= 256 * 1024, d.dropFirst(2).allSatisfy(\.isHexDigit) { data = d }
            case .insufficientFunds(let m):
                code = -32003
                detail = Self.sanitize(m)
            case .broadcastUncertain:
                message = "Broadcast outcome uncertain; reconcile the signed transaction"
            case .noProviders:
                detail = "no RPC providers configured"
            case .invalidResponse, .allProvidersFailed:
                break
            }
        } else if error is TimeoutError {
            detail = "request timed out"
        }
        if code == -32000 { code = -32002 }

        if method == "eth_getLogs" {
            let rank = AntLogScanErrors.rank(leaf)
            if rank == .timeout, !AntLogScanErrors.antShrinksOn(detail) {
                // A timeout ant cannot recognise must still make it halve
                // its window rather than give up.
                detail = "query timeout (\(detail))"
            } else if rank == .endpoint, AntLogScanErrors.antShrinksOn(detail),
                      !(leaf is WalletRPC.Error) || AntLogScanErrors.isEndpointLimit(detail) {
                // A throttle must not read as a range limit, or ant halves
                // and repeats the scan against the throttle.
                detail = "endpoint unavailable"
            }
        }
        let text = message ?? (code == 3 ? "Execution reverted" : "Chain request failed\(detail.isEmpty ? "" : ": \(detail)")")
        return ErrorReply(code: code, message: text, data: data)
    }

    /// The error worth reporting: the router's most useful failure sits
    /// first in `allProvidersFailed` (see `ErrorKeeper`).
    private static func leaf(_ error: Swift.Error) -> Swift.Error {
        if case .allProvidersFailed(let errors)? = error as? WalletRPC.Error, let first = errors.first {
            return leaf(first)
        }
        return error
    }

    /// Desktop `sanitizeErrorMessage`: no URLs (they may carry API keys),
    /// no control characters, bounded length.
    static func sanitize(_ message: String) -> String {
        var text = message.replacingOccurrences(
            of: #"\b[a-z][a-z0-9+.-]*://[^\s;,)]+"#, with: "[url]", options: [.regularExpression, .caseInsensitive]
        )
        text = String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String(text.prefix(maxErrorMessage))
    }

    // MARK: - JSON helpers

    /// A string (≤ 128) or an integer. JSON booleans also arrive as
    /// `NSNumber`, and `NSNumber(1) as? Bool` succeeds, so the boolean
    /// check has to look at the encoded type, not the value — ant's
    /// requests all carry `"id": 1`.
    static func validID(_ id: Any) -> Bool {
        if let s = id as? String { return s.count <= 128 }
        guard let n = id as? NSNumber, String(cString: n.objCType) != "c" else { return false }
        return n.doubleValue == n.doubleValue.rounded()
    }

    static func errorBody(id: Any, code: Int, message: String, data: String? = nil) -> [String: Any] {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        return ["jsonrpc": "2.0", "id": id, "error": error]
    }

    static func encode(_ body: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private struct TimeoutError: Swift.Error {}

    private func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { @MainActor in try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimeoutError()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    var value: String?
}

/// Desktop's `rankLogScanError` and its needle lists: how useful a failed
/// `eth_getLogs` attempt is to ant, whose scan halves its window only
/// when the error text matches `is_range_limit_error`'s needles.
enum AntLogScanErrors {
    /// Ant v0.5.45 `is_range_limit_error` (crates/ant-chain/src/discover.rs).
    static let shrinkNeedles = [
        "block range", "range", "more than", "exceed", "too large", "10000", "limit",
        "logs matched", "response size", "up to a", "query timeout", "too many results",
    ]
    static let timeoutText = #"time(?:d)?[\s-]?out"#
    static let rangeSizeText = #"(?:max(?:imum)?|allowed|permitted) (?:block )?range|exceeds? (?:the )?(?:block )?range|(?:block )?range (?:is |of )?(?:too\b|larger|greater|wider|bigger|longer|more than|limit|exceed|limited|capped|size|span)|(?:limited to|up to) (?:an? )?[\w,.]+ (?:blocks? )?range"#
    static let requestLimitText = #"too many (?:results|logs|blocks)|response size|logs? matched|(?:returned )?more than [\d,]+ (?:results|logs|blocks)|(?:max(?:imum)?|too many) (?:number of )?(?:results|logs|blocks)|result(?:s| set)? (?:size |limit|too large|exceed)"#
    static let endpointLimitText = #"\brate\b|rate[\s-]?limit|too many requests|\b429\b|quota|credits?\b|daily request|capacity|requests? (?:per|limit)|throttl"#
    static let endpointStateText = #"beyond (?:the )?(?:current |latest )?(?:executed )?(?:head|latest|chain)|(?:still |is )syncing|not (?:yet )?synced|head block|latest executed block"#

    static func antShrinksOn(_ message: String) -> Bool {
        let lower = message.lowercased()
        return shrinkNeedles.contains { lower.contains($0) }
    }

    static func isEndpointLimit(_ message: String) -> Bool { matches(endpointLimitText, message) }

    static func rank(_ error: Swift.Error) -> ChainDataRouter.ErrorRank {
        let message = ChainDataRouter.safeErrorMessage(error)
        let coded: Bool
        switch error as? WalletRPC.Error {
        case .rpc?, .insufficientFunds?: coded = true
        default: coded = false
        }
        if error is ChainSourceDeadline || (error as? URLError)?.code == .timedOut
            || ChainDataRouter.failureKind(error) == .timeout || matches(timeoutText, message) {
            return .timeout
        }
        if !coded || matches(endpointLimitText, message) || matches(endpointStateText, message) {
            return .endpoint
        }
        if !antShrinksOn(message) { return .endpoint }
        return matches(rangeSizeText, message) || matches(requestLimitText, message) ? .request : .hint
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Just enough RLP to read the chain id and the signature presence off a
/// raw transaction, so the bridge broadcasts only signed Gnosis
/// transactions (desktop checks the same with ethers' `Transaction.from`).
enum SignedTransactionInspector {
    /// The chain id of a *signed* transaction, or nil when the bytes are
    /// not a signed legacy (EIP-155) / 0x01 / 0x02 / 0x03 transaction.
    static func chainID(rawTransaction: String) -> Int? {
        guard let bytes = Data(hexString: rawTransaction), !bytes.isEmpty else { return nil }
        let first = bytes[bytes.startIndex]
        if first <= 0x7f {
            // Typed envelope: chainId is the first list item, signature the last three.
            guard (0x01...0x03).contains(first),
                  let items = RLP.decodeList(bytes.dropFirst()),
                  items.count >= 4, isSigned(Array(items.suffix(2))) else { return nil }
            return integer(items[0])
        }
        // Legacy: [nonce, gasPrice, gas, to, value, data, v, r, s]; EIP-155 v = chainId*2 + 35/36.
        guard let items = RLP.decodeList(bytes), items.count == 9, isSigned(Array(items.suffix(2))),
              let v = integer(items[6]), v >= 35 else { return nil }
        return (v - 35) / 2
    }

    private static func isSigned(_ rs: [Data]) -> Bool {
        rs.count == 2 && rs.allSatisfy { !$0.isEmpty && $0.contains { $0 != 0 } }
    }

    private static func integer(_ data: Data) -> Int? {
        guard data.count <= 8 else { return nil }
        return data.reduce(0) { $0 << 8 | Int($1) }
    }

    enum RLP {
        /// Decode one top-level RLP list into its raw items (nested lists
        /// are returned as their encoded bytes, which is all the
        /// inspector needs).
        static func decodeList(_ data: Data) -> [Data]? {
            guard let (payload, consumed) = decodeItem(data), consumed == data.count, payload.isList else { return nil }
            var items: [Data] = []
            var rest = payload.bytes
            while !rest.isEmpty {
                guard let (item, used) = decodeItem(rest) else { return nil }
                items.append(item.isList ? rest.prefix(used) : item.bytes)
                rest = rest.dropFirst(used)
            }
            return items
        }

        private struct Item {
            let bytes: Data
            let isList: Bool
        }

        private static func decodeItem(_ data: Data) -> (Item, Int)? {
            guard let prefix = data.first else { return nil }
            let d = Data(data)
            func slice(_ offset: Int, _ length: Int) -> Data? {
                guard offset + length <= d.count else { return nil }
                return d.subdata(in: offset..<(offset + length))
            }
            switch prefix {
            case 0x00...0x7f:
                return (Item(bytes: Data([prefix]), isList: false), 1)
            case 0x80...0xb7:
                let len = Int(prefix - 0x80)
                guard let bytes = slice(1, len) else { return nil }
                return (Item(bytes: bytes, isList: false), 1 + len)
            case 0xb8...0xbf:
                let lenLen = Int(prefix - 0xb7)
                guard let lenBytes = slice(1, lenLen), let len = length(lenBytes), let bytes = slice(1 + lenLen, len) else { return nil }
                return (Item(bytes: bytes, isList: false), 1 + lenLen + len)
            case 0xc0...0xf7:
                let len = Int(prefix - 0xc0)
                guard let bytes = slice(1, len) else { return nil }
                return (Item(bytes: bytes, isList: true), 1 + len)
            default:
                let lenLen = Int(prefix - 0xf7)
                guard let lenBytes = slice(1, lenLen), let len = length(lenBytes), let bytes = slice(1 + lenLen, len) else { return nil }
                return (Item(bytes: bytes, isList: true), 1 + lenLen + len)
            }
        }

        private static func length(_ bytes: Data) -> Int? {
            guard bytes.count <= 4 else { return nil }
            return bytes.reduce(0) { $0 << 8 | Int($1) }
        }
    }
}

private extension Data {
    init?(hexString: String) {
        var hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard hex.count % 2 == 0, hex.allSatisfy(\.isHexDigit) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        while !hex.isEmpty {
            let pair = hex.prefix(2)
            hex = String(hex.dropFirst(2))
            bytes.append(UInt8(pair, radix: 16)!)
        }
        self.init(bytes)
    }
}
