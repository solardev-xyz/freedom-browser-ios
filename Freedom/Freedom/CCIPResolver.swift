import Foundation
import Network
import web3

/// EIP-3668 CCIP-Read retry loop. When a resolver reverts with the
/// `OffchainLookup(address,string[],bytes,bytes4,bytes)` custom error,
/// the client is expected to:
///   1. POST/GET the specified gateway URL(s) with the callData.
///   2. Re-issue the eth_call against `address.callbackFunction(response, extraData)`
///      at the same pinned block.
///   3. Accept the final return value as the real resolve result.
/// Our existing `QuorumLeg` detects the revert; this type performs the
/// hop + callback and returns the final hex. Bounded recursion — a
/// callback may itself revert with OffchainLookup.
///
/// We reimplement the parse + callback-encode pieces because web3.swift
/// ships them internal-only. OffchainLookup (the struct) is public, so
/// we lean on its public `expectedTypes` + the ABIFunctionEncodable
/// `decode(_:expectedTypes:filteringEmptyEntries:)` protocol method —
/// both are part of web3.swift's public API.
enum CCIPResolver {
    enum CCIPError: Error, Equatable {
        case parseFailure
        case allGatewaysFailed
        case clientError(status: Int)
        case tooManyRedirects
    }

    struct GatewayRequest: Equatable {
        let url: URL
        /// HTTP verb — EIP-3668 picks GET when the URL template contains
        /// `{data}`, POST otherwise. Kept as a String to avoid pulling in
        /// URLSession types at this layer (tests mock the client).
        let method: String
        let body: Data?
    }

    struct GatewayResponse: Equatable {
        let status: Int
        let body: Data
    }

    typealias HTTPClient = @Sendable (GatewayRequest, TimeInterval) async throws -> GatewayResponse
    typealias EthCallExecutor = @Sendable (_ to: String, _ dataHex: String) async throws -> String

    /// `bytes4(keccak256("OffchainLookup(address,string[],bytes,bytes4,bytes)"))`.
    static let offchainLookupSelector = "0x556f1830"

    /// Matches ethers.js default. A cap is required by the EIP to prevent
    /// a hostile gateway from spinning the client forever via new reverts.
    static let maxRedirects = 4

    static func resolve(
        revertData: Data,
        ethCall: @escaping EthCallExecutor,
        http: @escaping HTTPClient,
        timeout: TimeInterval,
        depth: Int = 0
    ) async throws -> String {
        guard depth <= maxRedirects else { throw CCIPError.tooManyRedirects }

        let lookup = try parseOffchainLookup(data: revertData)
        let gatewayBytes = try await fetchFromGateways(lookup: lookup, http: http, timeout: timeout)
        let callback = encodeCallback(lookup: lookup, gatewayResponse: gatewayBytes)

        do {
            return try await ethCall(lookup.address.asString(), callback.web3.hexString)
        } catch let RPCError.executionRevert(innerHex) {
            // Per EIP-3668 the callback may itself revert with OffchainLookup.
            // Every other revert is terminal — re-throw as-is so the leg
            // classifies it normally (e.g. NO_CONTENTHASH, NO_RESOLVER).
            guard let hex = innerHex,
                  selectorOf(hex) == offchainLookupSelector,
                  let bytes = hex.web3.hexData else {
                throw RPCError.executionRevert(data: innerHex)
            }
            return try await resolve(
                revertData: bytes, ethCall: ethCall, http: http,
                timeout: timeout, depth: depth + 1
            )
        }
    }

    static func parseOffchainLookup(data: Data) throws -> OffchainLookup {
        // Instantiating via the public init gives us a protocol-conforming
        // OffchainLookup whose expectedTypes match the revert. The values
        // passed are placeholders — `decode()` ignores them and only uses
        // the types list computed from encode(to:).
        let placeholder = OffchainLookup(
            address: .zero, urls: [], callData: Data(),
            callbackFunction: Data(repeating: 0, count: 4), extraData: Data()
        )
        let decoded: [ABIDecoder.DecodedValue]
        do {
            decoded = try placeholder.decode(
                data, expectedTypes: placeholder.expectedTypes,
                filteringEmptyEntries: false
            )
        } catch {
            throw CCIPError.parseFailure
        }
        guard decoded.count == 5 else { throw CCIPError.parseFailure }
        do {
            return try OffchainLookup(
                address: decoded[0].decoded(),
                urls: decoded[1].decodedArray(),
                callData: decoded[2].decoded(),
                callbackFunction: decoded[3].decoded(),
                extraData: decoded[4].decoded()
            )
        } catch {
            throw CCIPError.parseFailure
        }
    }

    /// `callbackFunction || abi.encode(bytes gatewayResponse, bytes extraData)`.
    /// ABIFunctionEncoder always prefixes a 4-byte method id computed from
    /// its name; we use a throwaway name, drop the prefix, and prepend the
    /// real callback selector. Produces the same bytes as web3.swift's
    /// internal `encodeCall(withResponse:)` since both go through
    /// `encodedValues.encoded(isDynamic: false)`.
    static func encodeCallback(lookup: OffchainLookup, gatewayResponse: Data) -> Data {
        let encoder = ABIFunctionEncoder("ccipCallback")
        do {
            try encoder.encode(gatewayResponse)
            try encoder.encode(lookup.extraData)
            let encoded = try encoder.encoded()
            return lookup.callbackFunction + encoded.dropFirst(4)
        } catch {
            return lookup.callbackFunction
        }
    }

    private static func fetchFromGateways(
        lookup: OffchainLookup,
        http: @escaping HTTPClient,
        timeout: TimeInterval
    ) async throws -> Data {
        let sender = lookup.address.asString().lowercased()
        let callDataHex = lookup.callData.web3.hexString
        for template in lookup.urls {
            // Cooperative cancellation — a cancelled wave (e.g. another leg
            // hit M) must stop this one from hammering the next gateway.
            try Task.checkCancellation()
            guard let req = buildRequest(
                template: template, sender: sender, callData: callDataHex
            ) else { continue }

            let resp: GatewayResponse
            do {
                resp = try await http(req, timeout)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
            // EIP-3668: 4xx terminates for ALL gateways (client-side error
            // is deterministic). 3xx in practice means `ccipSession`
            // refused a redirect — treat as "try next", same as 5xx or a
            // parse failure. Anything outside 2xx-or-4xx is "try next".
            if (400..<500).contains(resp.status) {
                throw CCIPError.clientError(status: resp.status)
            }
            guard (200..<300).contains(resp.status),
                  let data = parseGatewayBody(resp.body) else { continue }
            return data
        }
        throw CCIPError.allGatewaysFailed
    }

    static func buildRequest(template: String, sender: String, callData: String) -> GatewayRequest? {
        if template.contains("{data}") {
            let substituted = template
                .replacingOccurrences(of: "{sender}", with: sender)
                .replacingOccurrences(of: "{data}", with: callData)
            guard let url = URL(string: substituted), isSafeGatewayURL(url) else { return nil }
            return GatewayRequest(url: url, method: "GET", body: nil)
        }
        let substituted = template.replacingOccurrences(of: "{sender}", with: sender)
        guard let url = URL(string: substituted), isSafeGatewayURL(url) else { return nil }
        let payload: [String: String] = ["sender": sender, "data": callData]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return GatewayRequest(url: url, method: "POST", body: body)
    }

    /// Block gateway URLs that could steer a CCIP leg at local / private
    /// network targets. Each leg fires its gateway request from a single
    /// untrusted RPC revert, before any quorum agreement. Not covered:
    /// DNS names that resolve to private IPs (DNS rebinding) — stopping
    /// that needs resolved-address pinning through connect, which URLSession
    /// doesn't expose.
    static func isSafeGatewayURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard let host = url.host, !host.isEmpty else { return false }

        let lowered = host.lowercased()
        if lowered == "localhost" || lowered == "localhost.localdomain" { return false }
        if lowered.hasSuffix(".local") { return false }

        if let v4 = IPv4Address(host) { return !isUnsafeIPv4(v4) }
        // URL.host strips IPv6 brackets, but be defensive.
        let v6Candidate = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast()) : host
        if let v6 = IPv6Address(v6Candidate) { return !isUnsafeIPv6(v6) }
        return true
    }

    // IPv4/IPv6 parsing via `Network` types gives us strict literal
    // validation (e.g. a hostname that happens to contain digits won't
    // masquerade as an IP). Classification is byte-level and explicit
    // — `IPv4Address.isLoopback` turns out to only catch 127.0.0.1,
    // not the whole 127/8, so we can't rely on the stdlib predicates.

    private static func isUnsafeIPv4(_ addr: IPv4Address) -> Bool {
        let b = [UInt8](addr.rawValue)
        if b[0] == 127 { return true }                                     // 127/8 loopback
        if b[0] == 10 { return true }                                      // 10/8 private
        if b[0] == 172, (16...31).contains(b[1]) { return true }           // 172.16/12 private
        if b[0] == 192, b[1] == 168 { return true }                        // 192.168/16 private
        if b[0] == 169, b[1] == 254 { return true }                        // 169.254/16 link-local
        if b[0] == 0 { return true }                                       // 0/8 "this net"
        if (224...239).contains(b[0]) { return true }                      // 224/4 multicast
        if b == [255, 255, 255, 255] { return true }                       // broadcast
        return false
    }

    private static func isUnsafeIPv6(_ addr: IPv6Address) -> Bool {
        let b = [UInt8](addr.rawValue)
        // IPv4-mapped (::ffff:a.b.c.d) and deprecated IPv4-compatible
        // (::a.b.c.d, RFC 4291) smuggle a v4 address through v6; route
        // the trailing 4 bytes through the v4 classifier so loopback/
        // private targets don't slip past.
        if addr.isIPv4Mapped { return embeddedIPv4Unsafe(b) }
        if b.allSatisfy({ $0 == 0 }) { return true }                       // :: unspecified
        if b[0..<15].allSatisfy({ $0 == 0 }), b[15] == 1 { return true }   // ::1 loopback
        if b[0..<12].allSatisfy({ $0 == 0 }) { return embeddedIPv4Unsafe(b) }
        if b[0] == 0xFE, (b[1] & 0xC0) == 0x80 { return true }             // fe80::/10 link-local
        if (b[0] & 0xFE) == 0xFC { return true }                           // fc00::/7 unique-local
        if b[0] == 0xFF { return true }                                    // ff00::/8 multicast
        return false
    }

    private static func embeddedIPv4Unsafe(_ v6Bytes: [UInt8]) -> Bool {
        IPv4Address(Data(v6Bytes.suffix(4))).map(isUnsafeIPv4) ?? true
    }

    static func parseGatewayBody(_ data: Data) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hex = json["data"] as? String else { return nil }
        return hex.web3.hexData
    }

    static func selectorOf(_ hex: String) -> String? {
        guard hex.hasPrefix("0x"), hex.count >= 10 else { return nil }
        return String(hex.prefix(10)).lowercased()
    }

    /// Production HTTP client. Uses a dedicated session that refuses
    /// HTTP redirects: `isSafeGatewayURL` only validates the initial
    /// URL, and URLSession's default redirect-follow would let a
    /// safe-looking gateway 302 the client to `https://127.0.0.1/...`
    /// or RFC1918 targets, bypassing the gate entirely. EIP-3668
    /// gateways return direct JSON, so refusing redirects is correct
    /// semantics per the spec as well.
    nonisolated static let defaultHTTP: HTTPClient = { request, timeout in
        var builder = URLRequest(url: request.url)
        builder.httpMethod = request.method
        if let body = request.body {
            builder.setValue("application/json", forHTTPHeaderField: "Content-Type")
            builder.httpBody = body
        }
        let session = ccipSession
        let req = builder
        let (data, response) = try await RPCSession.withTimeout(seconds: timeout) {
            try await session.data(for: req)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return GatewayResponse(status: status, body: data)
    }

    nonisolated static let ccipSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 30
        return URLSession(
            configuration: config,
            delegate: NoRedirectDelegate(),
            delegateQueue: nil
        )
    }()

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
