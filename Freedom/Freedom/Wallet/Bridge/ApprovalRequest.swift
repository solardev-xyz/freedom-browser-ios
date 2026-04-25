import BigInt
import Foundation
import web3

/// Parked user decision while an approval sheet is visible. Same instance
/// reaches both the sheet (tap-to-decide) and the presenting Binding
/// (swipe-to-dismiss ⇒ implicit deny), so the resolver must be fire-once —
/// `CheckedContinuation.resume` double-dispatch is a precondition failure.
@MainActor
final class ApprovalResolver {
    private var continuation: CheckedContinuation<ApprovalRequest.Decision, Never>?

    init(_ continuation: CheckedContinuation<ApprovalRequest.Decision, Never>) {
        self.continuation = continuation
    }

    func resolve(_ decision: ApprovalRequest.Decision) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: decision)
    }
}

@MainActor
struct ApprovalRequest: Identifiable {
    enum Kind {
        case connect
        case personalSign(PersonalSignCoder.Preview)
        case typedData(TypedData)
        case sendTransaction(SendTransactionDetails)
        case switchChain(SwitchChainDetails)
    }

    enum Decision {
        case approved
        case denied
    }

    let id: UUID
    let origin: OriginIdentity
    let kind: Kind
    let resolver: ApprovalResolver

    func decide(_ decision: Decision) {
        resolver.resolve(decision)
    }
}

struct SendTransactionDetails {
    let to: EthereumAddress
    let valueWei: BigUInt
    let data: Data
    let quote: TransactionService.Quote
    let chain: Chain
    var recipientName: String? = nil
    var autoApproveOffer: AutoApproveOffer? = nil
}

/// Eligibility envelope for the `ApproveTxSheet` auto-approve toggle.
/// On approve+toggle-on the sheet hands this back to `AutoApproveStore`,
/// which keys the rule on the same fields.
struct AutoApproveOffer: Equatable {
    let origin: String
    let contract: EthereumAddress
    let selector: String
    let selectorLabel: String?
    let chainID: Int

    /// Eligibility: ≥4 data bytes, non-zero selector, `valueWei == 0`. A
    /// payable variant of an otherwise-trusted selector re-prompts —
    /// the user's prior consent didn't extend to "send funds along too".
    static func make(
        origin: String,
        to: EthereumAddress,
        valueWei: BigUInt,
        data: Data,
        chainID: Int
    ) -> AutoApproveOffer? {
        guard valueWei == 0, let selector = selectorHex(from: data) else { return nil }
        return AutoApproveOffer(
            origin: origin,
            contract: to,
            selector: selector,
            selectorLabel: ERC20Selectors.label(for: selector),
            chainID: chainID
        )
    }

    static func selectorHex(from data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let head = Data(data.prefix(4))
        guard !head.allSatisfy({ $0 == 0 }) else { return nil }
        return head.web3.hexString
    }
}

/// Payload for `wallet_switchEthereumChain`. Both chains resolved against
/// `ChainRegistry` before the sheet shows; unknown chains short-circuit
/// with EIP-3326's `4902` before reaching the sheet.
struct SwitchChainDetails {
    let from: Chain
    let to: Chain
}
