import Foundation
import SwarmKit

/// Owns the in-flight Bee identity swap — kicked off by vault create /
/// import / wipe, observed by the status bar and the failure-modal hook
/// in `ContentView`. Decouples the wallet UX from bee-lite's restart
/// (~10-15s); the user sees the wallet succeed in ~1s and the swap
/// finishes in the background.
///
/// One swap at a time. Re-entry cancels the prior task and starts a new
/// one. The coordinator remembers what to re-run for `retry()`.
@MainActor
@Observable
final class BeeIdentityCoordinator {
    enum Status: Equatable {
        case idle
        case swapping
        case failed(message: String)
    }

    typealias InjectionWork = @MainActor (Vault, SwarmNode) async throws -> Void
    typealias RevertWork = @MainActor (SwarmNode) async throws -> Void

    private(set) var status: Status = .idle

    /// Bool accessor for the alert's `isPresented:` binding — keeps the
    /// `Status` enum's case shape inside this file so the view layer
    /// doesn't pattern-match coordinator internals.
    var isFailed: Bool { failedMessage != nil }

    /// Message accessor for the alert's `presenting:` slot. Returns nil
    /// for non-failed states.
    var failedMessage: String? {
        if case .failed(let m) = status { return m }
        return nil
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    /// Captured at start so the modal's Retry button can re-run the last
    /// operation without the caller reconstructing the inputs.
    @ObservationIgnored private var retryAction: (() -> Void)?
    @ObservationIgnored private let injectFn: InjectionWork
    @ObservationIgnored private let revertFn: RevertWork

    init(
        inject: @escaping InjectionWork = { try await BeeIdentityInjector.inject(vault: $0, swarm: $1) },
        revert: @escaping RevertWork = { try await BeeIdentityInjector.revertToAnonymous(swarm: $0) }
    ) {
        self.injectFn = inject
        self.revertFn = revert
    }

    func injectInBackground(vault: Vault, swarm: SwarmNode) {
        retryAction = { [weak self] in
            self?.injectInBackground(vault: vault, swarm: swarm)
        }
        run { [injectFn] in try await injectFn(vault, swarm) }
    }

    func revertInBackground(swarm: SwarmNode) {
        retryAction = { [weak self] in
            self?.revertInBackground(swarm: swarm)
        }
        run { [revertFn] in try await revertFn(swarm) }
    }

    /// No-op if there's no failure to recover from (e.g. user cancelled the
    /// alert first).
    func retry() {
        guard case .failed = status, let retryAction else { return }
        retryAction()
    }

    /// Drop a `.failed` state without retrying. Bee is left in whatever
    /// state the failed swap put it in; the user can wipe + recreate or
    /// trigger another swap to recover.
    func dismissError() {
        guard case .failed = status else { return }
        status = .idle
        retryAction = nil
    }

    /// Idempotent self-heal: if the vault has been unlocked and the bee
    /// node is running, but the bee node's wallet address differs from
    /// what the vault would derive at `m/44'/60'/0'/0/1`, kick off an
    /// inject. Catches the case where a previous swap was interrupted
    /// (app crashed mid-restart, force-quit, etc.).
    func checkAndHeal(vault: Vault, swarm: SwarmNode) {
        guard case .idle = status else { return }
        guard vault.state == .unlocked, swarm.status == .running else { return }
        guard let derived = try? vault.signingKey(at: .beeWallet).ethereumAddress else { return }
        if BeeIdentityInjector.addressesMatch(derived, swarm.walletAddress) { return }
        injectInBackground(vault: vault, swarm: swarm)
    }

    // MARK: - Private

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        task?.cancel()
        status = .swapping
        task = Task { [weak self] in
            do {
                try await work()
                guard let self, !Task.isCancelled else { return }
                self.status = .idle
                self.retryAction = nil
            } catch is CancellationError {
                // Superseded by a newer swap — newer task already moved
                // status forward. Nothing to do.
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.status = .failed(message: error.localizedDescription)
            }
        }
    }
}
