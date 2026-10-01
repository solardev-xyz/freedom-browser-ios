import BigInt
import Foundation

/// `ant_storage_quote` / `ant_storage_topup_quote` — the all-in price of
/// a plan in xDAI, against what the node wallet already holds. The
/// figures the user sees are the `*_display` strings ant formats.
struct StorageQuote: Codable, Equatable {
    let depth: UInt8
    let days: UInt64
    /// PLUR per chunk; passed back verbatim to the buy so the charge
    /// matches the quote.
    let amountPerChunk: String
    let totalCostBzz: String
    /// One-time xBZZ this purchase also puts behind the node's
    /// chequebook ("0" once it is funded). Part of the all-in figures.
    let settlementDepositPlur: String
    let settlementDepositBzz: String
    let capacityBytes: UInt64
    let accountBzzDisplay: String
    let accountXdai: String
    let accountXdaiDisplay: String
    /// PLUR the node still has to swap for; "0" when its wallet already
    /// holds the xBZZ (then `xdaiRequired` is only the gas reserve).
    let neededBzz: String
    let neededBzzDisplay: String
    /// Swap input plus ant's fixed gas reserve: what the node wallet
    /// must hold. Not the plan's price — see `totalCostBzz`.
    let xdaiRequiredDisplay: String
    /// How much more xDAI the node wallet needs before the buy can run.
    let xdaiToSendDisplay: String
    let sufficientFunds: Bool

    enum CodingKeys: String, CodingKey {
        case depth, days
        case amountPerChunk = "amount_per_chunk"
        case totalCostBzz = "total_cost_bzz"
        case settlementDepositPlur = "settlement_deposit_plur"
        case settlementDepositBzz = "settlement_deposit_bzz"
        case capacityBytes = "capacity_bytes"
        case accountBzzDisplay = "account_bzz_display"
        case accountXdai = "account_xdai"
        case accountXdaiDisplay = "account_xdai_display"
        case neededBzz = "needed_bzz"
        case neededBzzDisplay = "needed_bzz_display"
        case xdaiRequiredDisplay = "xdai_required_display"
        case xdaiToSendDisplay = "xdai_to_send_display"
        case sufficientFunds = "sufficient_funds"
    }

    var includesSettlementDeposit: Bool { (UInt64(settlementDepositPlur) ?? 0) > 0 }
    /// The node's own xBZZ already covers the plan; the xDAI asked for
    /// is just its transaction fees.
    var coveredByNodeBzz: Bool { (UInt64(neededBzz) ?? 0) == 0 }

    static func decode(_ json: String) throws -> StorageQuote {
        try JSONDecoder().decode(StorageQuote.self, from: Data(json.utf8))
    }
}

/// `ant_storage_settlement_deposit` — whether the chequebook actually
/// backs the cheques it signs.
struct SettlementDeposit: Codable, Equatable {
    let enabled: Bool
    let chequebook: String?
    let depositBzz: String
    let targetBzz: String
    let shortfallBzz: String
    let needsTopUp: Bool
    let xdaiToSendDisplay: String
    let sufficientFunds: Bool

    enum CodingKeys: String, CodingKey {
        case enabled, chequebook
        case depositBzz = "deposit_bzz"
        case targetBzz = "target_bzz"
        case shortfallBzz = "shortfall_bzz"
        case needsTopUp = "needs_top_up"
        case xdaiToSendDisplay = "xdai_to_send_display"
        case sufficientFunds = "sufficient_funds"
    }

    static func decode(_ json: String) throws -> SettlementDeposit {
        try JSONDecoder().decode(SettlementDeposit.self, from: Data(json.utf8))
    }
}

/// `ant_storage_status` — the plan ant stamps with.
struct StorageStatus: Codable, Equatable {
    let enabled: Bool
    let batchID: String?

    enum CodingKeys: String, CodingKey {
        case enabled
        case batchID = "batch_id"
    }

    static func decode(_ json: String) throws -> StorageStatus {
        try JSONDecoder().decode(StorageStatus.self, from: Data(json.utf8))
    }
}

/// How the user pays: plain xDAI to the node wallet.
enum StoragePayment {
    /// Round the funding amount up to the next whole cent so the user
    /// sends a clean figure with a hair of headroom, never less than the
    /// quote requires (AntDrive's rule).
    static func roundedUpXdai(_ xdai: String) -> String {
        guard let amount = Double(xdai) else { return xdai }
        let cents = (amount * 100 - 1e-6).rounded(.up)
        // `max(0, -0.0)` keeps the negative zero; compare instead.
        return String(format: "%.2f", cents <= 0 ? 0 : cents / 100)
    }

    /// Wei for an xDAI decimal string, or nil when it does not parse.
    static func wei(fromXdai xdai: String) -> BigUInt? {
        BalanceFormatter.parseAmount(xdai, decimals: 18)
    }

    /// EIP-681 payment request for any wallet: `ethereum:<node>@100?value=<wei>`.
    static func paymentURI(nodeAddress: String, xdai: String) -> String {
        let value = wei(fromXdai: xdai).map { "?value=\($0)" } ?? ""
        return "ethereum:\(nodeAddress)@\(Chain.gnosisID)\(value)"
    }
}
