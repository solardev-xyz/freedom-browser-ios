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
