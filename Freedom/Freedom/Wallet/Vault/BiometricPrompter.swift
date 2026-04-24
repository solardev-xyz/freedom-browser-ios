import Foundation
import LocalAuthentication

/// Abstracts the `LAContext` prompt so `VaultCrypto` can be driven by a
/// deterministic stub in tests (biometric prompts can't be responded to
/// from a unit-test context).
protocol BiometricPrompter: Sendable {
    func canPrompt() -> Bool
    func prompt(reason: String) async throws
}

struct LocalAuthenticationPrompter: BiometricPrompter {
    func canPrompt() -> Bool {
        let ctx = LAContext()
        var err: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
    }

    func prompt(reason: String) async throws {
        let ctx = LAContext()
        try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<Void, Swift.Error>) in
            ctx.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            ) { success, error in
                if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: error ?? LAError(.authenticationFailed))
                }
            }
        }
    }
}
