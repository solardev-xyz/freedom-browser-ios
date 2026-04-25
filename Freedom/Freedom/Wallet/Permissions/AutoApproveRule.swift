import Foundation
import SwiftData
import web3

/// SwiftData has no native compound `.unique` constraint, so the
/// `(origin, contract, selector, chainID)` tuple is folded into the
/// `key` string and stored explicitly for `.unique` enforcement.
@Model
final class AutoApproveRule {
    @Attribute(.unique) var key: String
    var origin: String
    var contract: String
    var selector: String
    var chainID: Int
    var grantedAt: Date

    init(offer: AutoApproveOffer, grantedAt: Date = .now) {
        let normalizedContract = offer.contract.asString().lowercased()
        let normalizedSelector = offer.selector.lowercased()
        self.origin = offer.origin
        self.contract = normalizedContract
        self.selector = normalizedSelector
        self.chainID = offer.chainID
        self.grantedAt = grantedAt
        self.key = Self.makeKey(
            origin: offer.origin,
            contract: normalizedContract,
            selector: normalizedSelector,
            chainID: offer.chainID
        )
    }

    static func makeKey(offer: AutoApproveOffer) -> String {
        makeKey(
            origin: offer.origin,
            contract: offer.contract.asString().lowercased(),
            selector: offer.selector.lowercased(),
            chainID: offer.chainID
        )
    }

    static func makeKey(origin: String, contract: String, selector: String, chainID: Int) -> String {
        "\(origin)|\(contract)|\(selector)|\(chainID)"
    }
}
