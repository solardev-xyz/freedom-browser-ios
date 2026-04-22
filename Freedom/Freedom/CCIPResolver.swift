import Foundation
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
            // EIP-3668: 4xx terminates the lookup for ALL urls (client-side
            // error is deterministic across gateways); 5xx falls through to
            // the next URL. We extend the 5xx-retry treatment to transport
            // failures and unparseable bodies — treat anything but 4xx as
            // "try next" so one flaky gateway can't cancel the whole query.
            if (400..<500).contains(resp.status) {
                throw CCIPError.clientError(status: resp.status)
            }
            if resp.status >= 500 { continue }
            guard let data = parseGatewayBody(resp.body) else { continue }
            return data
        }
        throw CCIPError.allGatewaysFailed
    }

    static func buildRequest(template: String, sender: String, callData: String) -> GatewayRequest? {
        if template.contains("{data}") {
            let substituted = template
                .replacingOccurrences(of: "{sender}", with: sender)
                .replacingOccurrences(of: "{data}", with: callData)
            guard let url = URL(string: substituted) else { return nil }
            return GatewayRequest(url: url, method: "GET", body: nil)
        }
        let substituted = template.replacingOccurrences(of: "{sender}", with: sender)
        guard let url = URL(string: substituted) else { return nil }
        let payload: [String: String] = ["sender": sender, "data": callData]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return GatewayRequest(url: url, method: "POST", body: body)
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

    /// Production HTTP client. Separate from RPCSession.post because
    /// CCIP gateways speak REST (arbitrary URL / GET or POST / JSON
    /// body only on POST), not JSON-RPC. Reuses RPCSession.shared +
    /// withTimeout so connection pool behaviour is the same.
    nonisolated static let defaultHTTP: HTTPClient = { request, timeout in
        var builder = URLRequest(url: request.url)
        builder.httpMethod = request.method
        if let body = request.body {
            builder.setValue("application/json", forHTTPHeaderField: "Content-Type")
            builder.httpBody = body
        }
        let session = RPCSession.shared
        let req = builder
        let (data, response) = try await RPCSession.withTimeout(seconds: timeout) {
            try await session.data(for: req)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return GatewayResponse(status: status, body: data)
    }
}
