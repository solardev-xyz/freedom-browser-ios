import BigInt
import Foundation

/// An EIP-681 `ethereum:` payment request — the native-asset subset
/// desktop accepts (`src/renderer/lib/ethereum-uri.js`):
///
///     ethereum:<0xAddress | name>[@<chainId>][?value=<wei>][&label=<text>]
///
/// Function-call forms (`ethereum:<token>@<chain>/transfer?...`) are
/// refused outright so a tip link can never be mistaken for an ERC-20
/// transfer. Nothing is resolved, checksummed or looked up here —
/// `SendRequest.make` owns those semantics.
struct EthereumURI: Equatable {
    /// A `0x` address or a name the Send form can resolve (`.eth`,
    /// `.wei`, `.gwei`, a DNS-imported name).
    let target: String
    /// EIP-681 defaults to mainnet when the `@chainId` suffix is absent.
    let chainID: Int
    /// Exact wei; `nil` when the link names no amount.
    let valueWei: BigUInt?
    let label: String?

    enum ParseError: Error, Equatable {
        case notEthereumURI
        case malformed
        case unsupportedFunction
    }

    static let scheme = "ethereum"

    static func isEthereumURI(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("\(scheme):")
    }

    static func parse(_ raw: String) -> Result<EthereumURI, ParseError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEthereumURI(trimmed) else { return .failure(.notEthereumURI) }
        var body = String(trimmed.dropFirst(scheme.count + 1))

        var query = ""
        if let q = body.firstIndex(of: "?") {
            query = String(body[body.index(after: q)...])
            body = String(body[..<q])
        }
        // `/transfer`, `/approve`, …: a contract call, not a payment.
        if body.contains("/") { return .failure(.unsupportedFunction) }

        var target = body
        var chainID = 1
        if let at = body.firstIndex(of: "@") {
            target = String(body[..<at])
            let chainText = body[body.index(after: at)...]
            guard Self.isDigits(chainText), let id = Int(chainText), id > 0 else { return .failure(.malformed) }
            chainID = id
        }
        // WebKit percent-encodes a non-ASCII label in an href
        // (`ethereum:%F0%9F%A6%87.eth`); the resolver wants the name.
        target = target.removingPercentEncoding ?? target
        guard !target.isEmpty else { return .failure(.malformed) }
        guard Hex.isAddressShape(target) || NameSystem.isPotentialEnsName(target) else {
            return .failure(.malformed)
        }

        let params = Self.queryItems(query)
        var valueWei: BigUInt?
        if let rawValue = params["value"] {
            guard let wei = parseWei(rawValue) else { return .failure(.malformed) }
            valueWei = wei
        }
        let label = params["label"].flatMap { $0.isEmpty ? nil : $0 }
        return .success(EthereumURI(target: target, chainID: chainID, valueWei: valueWei, label: label))
    }

    /// EIP-681 numbers: an integer, or scientific notation (`1e18`,
    /// `1.5e17`) that still lands on a whole number of wei. No signs, no
    /// fractional wei (`0.1`, `1.5e0`). Exponents past what fits a
    /// 256-bit value are refused rather than computed.
    static func parseWei(_ s: String) -> BigUInt? {
        let parts = s.lowercased().split(separator: "e", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return nil }
        var exponent = 0
        if parts.count == 2 {
            guard isDigits(parts[1]), let e = Int(parts[1]), e <= 80 else { return nil }
            exponent = e
        }
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(mantissa.count), isDigits(mantissa[0]) else { return nil }
        let fraction = mantissa.count == 2 ? mantissa[1] : ""
        if mantissa.count == 2 { guard isDigits(fraction) else { return nil } }
        let shift = exponent - fraction.count
        guard shift >= 0, let digits = BigUInt(String(mantissa[0] + fraction)) else { return nil }
        return digits * BigUInt(10).power(shift)
    }

    /// Exact decimal for the Send form's amount field (`BalanceFormatter`
    /// truncates for display; a payment request must not).
    static func decimalString(wei: BigUInt, decimals: Int) -> String {
        let divisor = BigUInt(10).power(decimals)
        let whole = wei / divisor
        let remainder = wei % divisor
        if remainder == 0 { return "\(whole)" }
        let raw = String(remainder)
        let padded = String(repeating: "0", count: decimals - raw.count) + raw
        let trimmed = String(padded.reversed().drop(while: { $0 == "0" }).reversed())
        return "\(whole).\(trimmed)"
    }

    private static func isDigits(_ s: Substring) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// `URLSearchParams` semantics: `+` is a space, percent-escapes
    /// decode, a repeated key keeps its first value.
    private static func queryItems(_ query: String) -> [String: String] {
        var items: [String: String] = [:]
        for pair in query.split(separator: "&") where !pair.isEmpty {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = decode(kv[0])
            let value = kv.count == 2 ? decode(kv[1]) : ""
            if items[key] == nil { items[key] = value }
        }
        return items
    }

    private static func decode(_ s: Substring) -> String {
        let plusDecoded = s.replacingOccurrences(of: "+", with: " ")
        return plusDecoded.removingPercentEncoding ?? plusDecoded
    }
}

/// What an `ethereum:` link becomes once the chain is known: the Send
/// form's prefill. The user can still edit every field.
struct SendRequest: Hashable {
    let chain: Chain
    let recipient: String
    /// Decimal amount in the chain's native asset, or `nil` when the
    /// link names none (or names zero).
    let amount: String?

    enum Refusal: Error, Equatable {
        case unsupportedFunction
        case malformed(String)
        case unknownChain(Int)

        var message: String {
            switch self {
            case .unsupportedFunction:
                "ERC-20 and other contract-call ethereum: links aren't supported yet."
            case .malformed(let raw):
                "Malformed ethereum: link: \(raw)"
            case .unknownChain(let id):
                "Chain \(id) isn't in your wallet. Add it under Settings → Chains first."
            }
        }
    }

    /// `chain` looks the EIP-681 chain ID up in the wallet's registry
    /// (built-in and user-added chains alike).
    static func make(from raw: String, chain lookup: (Int) -> Chain?) -> Result<SendRequest, Refusal> {
        let uri: EthereumURI
        switch EthereumURI.parse(raw) {
        case .success(let parsed): uri = parsed
        case .failure(.unsupportedFunction): return .failure(.unsupportedFunction)
        case .failure: return .failure(.malformed(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        guard let chain = lookup(uri.chainID) else { return .failure(.unknownChain(uri.chainID)) }
        let decimals = TokenRegistry.native(for: chain).decimals
        let amount = uri.valueWei.flatMap { wei -> String? in
            wei == 0 ? nil : EthereumURI.decimalString(wei: wei, decimals: decimals)
        }
        return .success(SendRequest(chain: chain, recipient: uri.target, amount: amount))
    }
}
